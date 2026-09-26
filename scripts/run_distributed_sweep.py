#!/usr/bin/env python3
"""Orquestrador local da varredura distribuída do Caliper (N instâncias, MQTT).

Roda na máquina do operador (mesmo lugar que já roda `terraform apply`), nunca
numa instância EC2 — a chave privada (var.private_key_path) nunca é copiada pra
dentro de nenhuma instância. O mesmo aninhamento repetição → função → TPS de
run_test_local.py: pra cada combinação, SSHa nas instâncias extras pra lançar
workers remotos em background, depois SSHa na instância A (bloqueante) pra
rodar o round via run_caliper_manager_distributed.sh. Ao final, depois do
upload pro Blob Storage, baixa (scp) uma cópia dos CSVs pra
infra-testes-indy-besu/caliper-results/<timestamp>/ no laptop do operador.

TPS_LIST/BENCHMARK_FILES/REPETITIONS e a lógica de espera de txpool-drain vêm
de run_test_local.py — mas em vez de importar um clone local desse arquivo
(que podia ficar desatualizado/divergente do que está de fato deployado),
este script busca esses valores via SSH direto do clone fresco que já existe
na instância A (feito pelo próprio setup do Caliper). Única fonte de verdade
continua sendo run_test_local.py; só o jeito de lê-lo mudou.

Dois jeitos de fornecer a configuração (IPs, workers, storage account, etc.):
  1) Direto por flags (--instance-a-host, --extra-hosts, ...) — é assim que o
     próprio `terraform apply` chama este script automaticamente (via main.tf,
     null_resource.run_distributed_sweep), interpolando os valores na hora, SEM
     rodar `terraform output` — rodar isso durante um apply em andamento travaria
     no lock do state, já que o processo pai (o apply) segura o lock o tempo todo.
  2) Via `terraform output -json` (--terraform-dir) — só funciona depois que um
     apply já terminou de verdade (lock liberado); use pra re-rodar a varredura
     manualmente sem repetir todas as flags.

Uso:
    # Automático (é o que o terraform apply já dispara sozinho)
    python3 run_distributed_sweep.py --instance-a-host ... --extra-hosts ... [...]

    # Manual, depois que o apply já terminou
    python3 run_distributed_sweep.py
    python3 run_distributed_sweep.py --functions createDid --tps-list 3000 --max-retries 1
    python3 run_distributed_sweep.py --dry-run
"""
import argparse
import json
import subprocess
import sys
import time
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
TF_DIR_DEFAULT = SCRIPT_DIR.parent
CALIPER_ROOT_REMOTE = "/home/ubuntu/tests-with-caliper/evaluation-contracts-indy-besu"

MAX_RETRIES_DEFAULT = 3
RETRY_DELAY_DEFAULT = 15
WORKER_STARTUP_GRACE_SECONDS = 5
SSH_TIMEOUT_ROUND = 1850  # > timeout 1800 interno do run_caliper_manager_distributed.sh


def fetch_remote_sweep_config(host, private_key_path, dry_run=False):
    """Busca TPS_LIST, BENCHMARK_FILES e REPETITIONS via SSH do run_test_local.py
    que já está clonado (fresco, do GitHub) na instância A — em vez de importar
    um clone local do tests-with-caliper, que podia ficar desatualizado/
    divergente do que está de fato deployado na instância que vai rodar os
    testes."""
    py_code = ("import json, run_test_local as rtl; "
               "print(json.dumps({'tps_list': rtl.TPS_LIST, 'benchmark_files': rtl.BENCHMARK_FILES, "
               "'repetitions': rtl.REPETITIONS}))")
    cmd = ["ssh", *ssh_opts(private_key_path), f"ubuntu@{host}",
           f"cd {CALIPER_ROOT_REMOTE} && python3 -c \"{py_code}\""]

    if dry_run:
        print(f"[dry-run] {' '.join(cmd)}")
        # Sem instância real pra consultar em --dry-run, usa uma amostra fixa só
        # pra dar forma ao preview — funções/TPS/repetições reais só saem numa
        # execução real.
        return {
            "tps_list": [2000, 3000, 5000],
            "repetitions": 1,
            "benchmark_files": {
                "createDid": "benchmarks/scenario/IndyDidRegistry/config-createDid.yaml",
                "updateDid": "benchmarks/scenario/IndyDidRegistry/config-updateDid.yaml",
                "createSchema": "benchmarks/scenario/SchemaRegistry/config.yaml",
                "createCredentialDefinition": "benchmarks/scenario/CredentialDefinitionRegistry/config.yaml",
                "createRevocationRegistry": "benchmarks/scenario/RevocationRegistry/config_createRevocationRegistry.yaml",
                "createOrUpdateEntry": "benchmarks/scenario/RevocationRegistry/config_createOrUpdateEntry.yaml",
            },
        }

    result = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
    if result.returncode != 0:
        print(f"ERRO: falha ao buscar TPS_LIST/BENCHMARK_FILES da instância A ({host}):\n{result.stderr}",
              file=sys.stderr)
        sys.exit(1)
    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError:
        print(f"ERRO: resposta inesperada da instância A ao buscar config:\n{result.stdout}", file=sys.stderr)
        sys.exit(1)


def wait_txpool_drain_remote(cfg, tps, dry_run=False):
    """Roda wait_txpool_drain() dentro da instância A, usando o run_test_local.py
    de lá — mesma lógica de polling/threshold que o modo single-instance já usa,
    sem duplicá-la aqui. max_wait escala com o tps do round que acabou de rodar
    (rtl.drain_max_wait_for_tps) — TPS maior deixa mais backlog, então precisa de
    mais tempo real pra drenar."""
    py_code = (f"import run_test_local as rtl; "
               f"rtl.wait_txpool_drain('{cfg.rpc_url}', max_wait=rtl.drain_max_wait_for_tps({tps}))")
    cmd = f"cd {CALIPER_ROOT_REMOTE} && python3 -c \"{py_code}\""
    # Timeout do SSH em si precisa cobrir o max_wait remoto + folga de conexão —
    # senão o cliente SSH mata o comando (e o polling junto) antes do prazo
    # remoto acabar. Mesma fórmula de rtl.drain_max_wait_for_tps; só existe aqui
    # pra dimensionar esse timeout local, sem duplicar a lógica de drenagem em si.
    ssh_timeout = 60 + max(120, int(120 * (tps / 1000)))
    ssh_run(cfg.instance_a_host, cfg.private_key_path, cmd, timeout=ssh_timeout, dry_run=dry_run)


def terraform_outputs(tf_dir):
    result = subprocess.run(
        ["terraform", "output", "-json"], cwd=tf_dir, capture_output=True, text=True
    )
    if result.returncode != 0:
        print(f"ERRO: 'terraform output -json' falhou em {tf_dir}:\n{result.stderr}", file=sys.stderr)
        sys.exit(1)
    raw = json.loads(result.stdout)
    return {k: v["value"] for k, v in raw.items()}


def ssh_opts(private_key_path):
    # UserKnownHostsFile=/dev/null é necessário além de StrictHostKeyChecking=no:
    # essa segunda flag só evita prompt pra host NOVO — se o known_hosts já tem
    # uma entrada antiga pro mesmo IP (Azure reaproveita IPs públicos entre
    # destroy/apply, e cada VM nova gera host key própria), o SSH trata como
    # possível ataque e recusa a conexão mesmo com StrictHostKeyChecking=no.
    return ["-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null",
            "-o", "ConnectTimeout=10", "-o", "BatchMode=yes", "-i", private_key_path]


def ssh_run(host, private_key_path, remote_cmd, timeout, dry_run=False):
    cmd = ["ssh", *ssh_opts(private_key_path), f"ubuntu@{host}", remote_cmd]
    if dry_run:
        print(f"[dry-run] {' '.join(cmd)}")
        return subprocess.CompletedProcess(cmd, 0)
    try:
        return subprocess.run(cmd, timeout=timeout)
    except subprocess.TimeoutExpired:
        print(f"⚠️ SSH pra {host} travou (timeout {timeout}s): {remote_cmd[:80]}...")
        return None


def scp_run(host, private_key_path, local_path, remote_path, dry_run=False):
    cmd = ["scp", *ssh_opts(private_key_path), str(local_path), f"ubuntu@{host}:{remote_path}"]
    if dry_run:
        print(f"[dry-run] {' '.join(cmd)}")
        return subprocess.CompletedProcess(cmd, 0)
    return subprocess.run(cmd)


def scp_download(host, private_key_path, remote_path, local_dir, dry_run=False):
    """Sentido inverso de scp_run() — baixa (remote_path pode ser um glob, ex.:
    ".../*.csv", expandido pelo shell do lado remoto) pra um diretório local que
    já precisa existir."""
    cmd = ["scp", *ssh_opts(private_key_path), f"ubuntu@{host}:{remote_path}", str(local_dir)]
    if dry_run:
        print(f"[dry-run] {' '.join(cmd)}")
        return subprocess.CompletedProcess(cmd, 0)
    return subprocess.run(cmd)


def upload_manager_files(cfg, dry_run=False):
    """Envia pra instância A os arquivos que run_manager_round()/patch_*() chamam
    por SSH"""
    for fname in ("run_caliper_manager_distributed.sh", "remote_patch_yaml.py"):
        local_path = SCRIPT_DIR / fname
        remote_path = f"{CALIPER_ROOT_REMOTE}/{fname}"
        r = scp_run(cfg.instance_a_host, cfg.private_key_path, local_path, remote_path, dry_run=dry_run)
        if not dry_run and (r is None or r.returncode != 0):
            raise RuntimeError(f"Falha ao enviar {fname} pra instância A — abortando sweep.")

    chmod_cmd = f"chmod +x {CALIPER_ROOT_REMOTE}/run_caliper_manager_distributed.sh"
    r = ssh_run(cfg.instance_a_host, cfg.private_key_path, chmod_cmd, timeout=15, dry_run=dry_run)
    if not dry_run and (r is None or r.returncode != 0):
        raise RuntimeError("Falha ao dar chmod +x em run_caliper_manager_distributed.sh — abortando sweep.")


def remote_has_csv(cfg, remote_dir, dry_run=False):
    """Confere via SSH se remote_dir existe e tem pelo menos um .csv — evita um
    scp que falharia (diretório nunca chega a ser criado quando todos os rounds
    de uma função falham; mesmo caso que extract_and_upload_results.sh já trata
    com `if [ -d "$DIR" ]` antes de subir pro Blob)."""
    cmd = f"ls {remote_dir}/*.csv >/dev/null 2>&1"
    r = ssh_run(cfg.instance_a_host, cfg.private_key_path, cmd, timeout=15, dry_run=dry_run)
    if dry_run:
        # Sem instância real pra checar em --dry-run, assume que existe, só pra
        # manter o preview completo (mesmo espírito do fetch_remote_sweep_config).
        return True
    return r is not None and r.returncode == 0


def download_results(cfg, dry_run=False):
    """Baixa da instância A, pra raiz do repo de infra no laptop do operador, os
    CSVs que extract_and_upload_results.sh acabou de extrair — mesma seleção de
    diretórios (por função testada neste sweep) que esse script já sobe pro Blob
    Storage, só que trazendo uma cópia local também, disponível logo depois do
    apply terminar."""
    timestamp = time.strftime("%Y%m%d-%H%M%S")
    local_base = SCRIPT_DIR.parent / "caliper-results" / timestamp

    for function_name in cfg.functions:
        resource_remote_dir = f"{CALIPER_ROOT_REMOTE}/src/{function_name}_resource_metrics_by_tps"
        reports_remote_dir = f"{CALIPER_ROOT_REMOTE}/src/reports/{function_name}"
        resource_dest = local_base / "resource_metrics" / f"{function_name}_resource_metrics_by_tps"
        reports_dest = local_base / "reports" / function_name

        if remote_has_csv(cfg, resource_remote_dir, dry_run=dry_run):
            if not dry_run:
                resource_dest.mkdir(parents=True, exist_ok=True)
            scp_download(cfg.instance_a_host, cfg.private_key_path,
                         f"{resource_remote_dir}/*.csv", resource_dest, dry_run=dry_run)
        elif not dry_run:
            print(f"AVISO: nenhum CSV de resource_metrics pra '{function_name}' na instância A "
                  f"(rounds dessa função falharam?) — pulando download.")

        if remote_has_csv(cfg, reports_remote_dir, dry_run=dry_run):
            if not dry_run:
                reports_dest.mkdir(parents=True, exist_ok=True)
            scp_download(cfg.instance_a_host, cfg.private_key_path,
                         f"{reports_remote_dir}/*.csv", reports_dest, dry_run=dry_run)
        elif not dry_run:
            print(f"AVISO: nenhum CSV de reports pra '{function_name}' na instância A "
                  f"(rounds dessa função falharam?) — pulando download.")

    if not dry_run:
        print(f"Resultados CSV baixados em {local_base}")


class Config:
    def __init__(self, args):
        if args.instance_a_host:
            # Modo direto — usado pelo terraform apply (main.tf), valores já
            # interpolados pelo próprio Terraform, sem chamar `terraform output`.
            missing = [f for f in ("extra_hosts", "instance_a_private_ip", "caliper_a_workers",
                                    "caliper_b_workers", "storage_account", "storage_container",
                                    "identity_client_id", "rpc_url", "private_key_path")
                       if getattr(args, f) is None]
            if missing:
                print(f"ERRO: --instance-a-host foi passado, mas faltam: {missing}", file=sys.stderr)
                sys.exit(1)
            self.instance_a_host = args.instance_a_host
            self.instance_a_private_ip = args.instance_a_private_ip
            self.extra_hosts = args.extra_hosts
            self.caliper_a_workers = args.caliper_a_workers
            self.caliper_b_workers = args.caliper_b_workers
            self.storage_account = args.storage_account
            self.storage_container = args.storage_container
            self.identity_client_id = args.identity_client_id
            self.rpc_url = args.rpc_url
            self.private_key_path = str(Path(args.private_key_path).expanduser())
        else:
            # Modo terraform-output — só seguro depois que o apply já terminou
            # (lock do state liberado). Ver docstring do módulo.
            outputs = terraform_outputs(args.terraform_dir)
            key_path = args.private_key_path or outputs["private_key_path"]
            self.private_key_path = str(Path(key_path).expanduser())
            self.instance_a_host = outputs["caliper_public_ip"]
            self.instance_a_private_ip = outputs["caliper_a_private_ip"]
            self.extra_hosts = outputs["caliper_b_public_ips"]
            self.caliper_a_workers = int(outputs["caliper_a_workers"])
            self.caliper_b_workers = int(outputs["caliper_b_workers"])
            self.storage_account = outputs["storage_account_name"]
            self.storage_container = outputs["storage_container_name"]
            self.identity_client_id = outputs["azure_identity_client_id"]
            self.rpc_url = outputs["rpc_url"]

        self.node_caliper_count = len(self.extra_hosts) + 1

        remote_cfg = fetch_remote_sweep_config(self.instance_a_host, self.private_key_path, dry_run=args.dry_run)

        self.tps_list = args.tps_list if args.tps_list else remote_cfg["tps_list"]
        all_functions = list(remote_cfg["benchmark_files"].keys())
        self.functions = args.functions if args.functions else all_functions
        for f in self.functions:
            if f not in remote_cfg["benchmark_files"]:
                print(f"ERRO: função '{f}' não existe em BENCHMARK_FILES ({all_functions})", file=sys.stderr)
                sys.exit(1)
        self.benchmark_files = {f: remote_cfg["benchmark_files"][f] for f in self.functions}
        self.repetitions = args.repetitions if args.repetitions else remote_cfg["repetitions"]


def patch_workers_number(cfg, benchmark_file, total_workers, dry_run=False):
    cmd = f"cd {CALIPER_ROOT_REMOTE} && python3 remote_patch_yaml.py {benchmark_file} number {total_workers}"
    r = ssh_run(cfg.instance_a_host, cfg.private_key_path, cmd, timeout=30, dry_run=dry_run)
    if not dry_run and (r is None or r.returncode != 0):
        raise RuntimeError(f"Falha ao patchar workers.number em {benchmark_file} — abortando sweep.")


def patch_tps(cfg, benchmark_file, tps, dry_run=False):
    cmd = f"cd {CALIPER_ROOT_REMOTE} && python3 remote_patch_yaml.py {benchmark_file} tps {tps}"
    r = ssh_run(cfg.instance_a_host, cfg.private_key_path, cmd, timeout=30, dry_run=dry_run)
    if not dry_run and (r is None or r.returncode != 0):
        raise RuntimeError(f"Falha ao patchar tps em {benchmark_file} — abortando sweep.")


def launch_remote_workers(cfg, benchmark_file, dry_run=False):
    for host in cfg.extra_hosts:
        cmd = (f"cd {CALIPER_ROOT_REMOTE} && "
               f"nohup ./launch_workers.sh {cfg.instance_a_private_ip} {cfg.caliper_b_workers} {benchmark_file} "
               f"> /home/ubuntu/launch_workers_last.log 2>&1 < /dev/null & disown")
        ssh_run(host, cfg.private_key_path, cmd, timeout=20, dry_run=dry_run)


def kill_stray_remote_workers(cfg, dry_run=False):
    for host in cfg.extra_hosts:
        ssh_run(host, cfg.private_key_path, "pkill -f 'caliper launch worker' || true", timeout=15, dry_run=dry_run)


def run_manager_round(cfg, benchmark_file, function_name, tps, dry_run=False):
    cmd = (f"cd {CALIPER_ROOT_REMOTE} && "
           f"./run_caliper_manager_distributed.sh {cfg.caliper_a_workers} {benchmark_file} {function_name} {tps}")
    r = ssh_run(cfg.instance_a_host, cfg.private_key_path, cmd, timeout=SSH_TIMEOUT_ROUND, dry_run=dry_run)
    return dry_run or (r is not None and r.returncode == 0)


def run_round(cfg, function_name, benchmark_file, tps, max_retries, retry_delay, dry_run=False):
    patch_tps(cfg, benchmark_file, tps, dry_run=dry_run)
    for attempt in range(1, max_retries + 1):
        launch_remote_workers(cfg, benchmark_file, dry_run=dry_run)
        if not dry_run:
            time.sleep(WORKER_STARTUP_GRACE_SECONDS)
        success = run_manager_round(cfg, benchmark_file, function_name, tps, dry_run=dry_run)
        kill_stray_remote_workers(cfg, dry_run=dry_run)
        if success:
            print(f"✅ {function_name}@{tps}TPS OK (tentativa {attempt}/{max_retries})")
            return
        print(f"⚠️ {function_name}@{tps}TPS tentativa {attempt}/{max_retries} falhou.")
        if attempt < max_retries and not dry_run:
            time.sleep(retry_delay)
            wait_txpool_drain_remote(cfg, tps, dry_run=dry_run)
    print(f"❌ Nenhum resultado válido para {function_name} @ {tps} TPS após {max_retries} tentativas (modo distribuído).")


def parse_args():
    p = argparse.ArgumentParser(description="Varredura distribuída do Caliper (N instâncias, MQTT).")
    p.add_argument("--terraform-dir", default=str(TF_DIR_DEFAULT),
                    help="Usado só quando --instance-a-host não é passado (lê via 'terraform output -json').")
    p.add_argument("--private-key-path", default=None,
                    help="Caminho da chave SSH. Obrigatório em modo direto; opcional (override) em modo terraform-output.")

    direct = p.add_argument_group("modo direto (usado pelo terraform apply — evita 'terraform output' durante o apply)")
    direct.add_argument("--instance-a-host", default=None, help="IP público da instância A (manager).")
    direct.add_argument("--instance-a-private-ip", default=None, help="IP privado da instância A (broker MQTT).")
    direct.add_argument("--extra-hosts", nargs="*", default=None, help="IPs públicos das instâncias extras.")
    direct.add_argument("--caliper-a-workers", type=int, default=None)
    direct.add_argument("--caliper-b-workers", type=int, default=None)
    direct.add_argument("--storage-account", default=None)
    direct.add_argument("--storage-container", default=None)
    direct.add_argument("--identity-client-id", default=None)
    direct.add_argument("--rpc-url", default=None)

    p.add_argument("--functions", nargs="+", default=None)
    p.add_argument("--tps-list", nargs="+", type=int, default=None)
    p.add_argument("--repetitions", type=int, default=None,
                    help="Quantas vezes repetir a varredura completa (todas as funções x todos os TPS). "
                         "Default: REPETITIONS de run_test_local.py, buscado da instância A.")
    p.add_argument("--max-retries", type=int, default=MAX_RETRIES_DEFAULT)
    p.add_argument("--retry-delay", type=int, default=RETRY_DELAY_DEFAULT)
    p.add_argument("--dry-run", action="store_true",
                    help="Imprime os comandos SSH que seriam executados, sem rodar nada de verdade.")
    return p.parse_args()


def main():
    args = parse_args()
    cfg = Config(args)

    if cfg.node_caliper_count <= 1:
        print("ERRO: node_caliper_count <= 1 — nada pra orquestrar. Rode "
              "'terraform apply -var=\"node_caliper_count=N\"' com N > 1 primeiro.", file=sys.stderr)
        sys.exit(1)

    total_workers = cfg.caliper_a_workers + len(cfg.extra_hosts) * cfg.caliper_b_workers
    print(f"Instância A: {cfg.instance_a_host} (privado {cfg.instance_a_private_ip})")
    print(f"Instâncias extras: {cfg.extra_hosts}")
    print(f"Total de workers por rodada: {total_workers} "
          f"({cfg.caliper_a_workers} local + {len(cfg.extra_hosts)}x{cfg.caliper_b_workers} remotos)")
    print(f"Funções: {cfg.functions}")
    print(f"TPS: {cfg.tps_list}")
    print(f"Repetições: {cfg.repetitions}")

    upload_manager_files(cfg, dry_run=args.dry_run)

    for benchmark_file in set(cfg.benchmark_files.values()):
        patch_workers_number(cfg, benchmark_file, total_workers, dry_run=args.dry_run)

    for repetition in range(1, cfg.repetitions + 1):
        print(f"\n{'='*50}\n🔁 Repetição {repetition}/{cfg.repetitions}\n{'='*50}")
        for function_name in cfg.functions:
            benchmark_file = cfg.benchmark_files[function_name]
            print(f"\n{'='*50}\n🚀 Iniciando testes para função: {function_name}\n{'='*50}")
            for tps in cfg.tps_list:
                run_round(cfg, function_name, benchmark_file, tps, args.max_retries, args.retry_delay, dry_run=args.dry_run)
                if not args.dry_run:
                    time.sleep(10)
                    wait_txpool_drain_remote(cfg, tps, dry_run=args.dry_run)

    print("\nVarredura distribuída concluída — extraindo CSVs e subindo pro Blob Storage...")
    extract_cmd = (f"CALIPER_ROOT={CALIPER_ROOT_REMOTE} AZURE_STORAGE_ACCOUNT={cfg.storage_account} "
                    f"AZURE_STORAGE_CONTAINER={cfg.storage_container} AZURE_IDENTITY_CLIENT_ID={cfg.identity_client_id} "
                    f"bash /tmp/extract_and_upload_results.sh")
    ssh_run(cfg.instance_a_host, cfg.private_key_path, extract_cmd, timeout=300, dry_run=args.dry_run)

    print("Baixando cópia local dos CSVs...")
    download_results(cfg, dry_run=args.dry_run)


if __name__ == "__main__":
    main()
