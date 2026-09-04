#!/usr/bin/env python3
"""Orquestrador local da varredura distribuída do Caliper (N instâncias, MQTT).

Roda na máquina do operador (mesmo lugar que já roda `terraform apply`), nunca
numa instância EC2 — a chave privada (var.private_key_path) nunca é copiada pra
dentro de nenhuma instância. Pra cada combinação de função x TPS (lidas direto de
run_test_local.py, única fonte de verdade), SSHa nas instâncias extras pra lançar
workers remotos em background, depois SSHa na instância A (bloqueante) pra rodar o
round via run_caliper_manager_distributed.sh, com a mesma lógica de retry/delay/
txpool-drain de run_test_local.py.

Dois jeitos de fornecer a configuração (IPs, workers, bucket, etc.):
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
import importlib.util
import json
import subprocess
import sys
import time
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
TF_DIR_DEFAULT = SCRIPT_DIR.parent
CALIPER_REPO_DEFAULT = SCRIPT_DIR.parent.parent / "tests-with-caliper" / "evaluation-contracts-indy-besu"
CALIPER_ROOT_REMOTE = "/home/ubuntu/tests-with-caliper/evaluation-contracts-indy-besu"

MAX_RETRIES_DEFAULT = 3
RETRY_DELAY_DEFAULT = 15
WORKER_STARTUP_GRACE_SECONDS = 5
SSH_TIMEOUT_ROUND = 650  # > timeout 600 interno do run_caliper_manager_distributed.sh


def load_run_test_local(caliper_repo_path):
    """Carrega run_test_local.py como módulo, sem executar o bloco
    `if __name__ == "__main__":` (só roda quando __name__ é literalmente
    "__main__", o que não é o caso ao importar — bind_caliper()/setup_issuer()
    não disparam à toa)."""
    path = Path(caliper_repo_path) / "run_test_local.py"
    if not path.exists():
        print(f"ERRO: {path} não existe. Use --caliper-repo-path pra apontar pro "
              f"clone local de tests-with-caliper/evaluation-contracts-indy-besu.", file=sys.stderr)
        sys.exit(1)
    spec = importlib.util.spec_from_file_location("run_test_local", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def distributed_path(non_distributed_path):
    assert non_distributed_path.endswith(".yaml")
    return non_distributed_path[: -len(".yaml")] + "-distributed.yaml"


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
    return ["-o", "StrictHostKeyChecking=no", "-o", "ConnectTimeout=10",
            "-o", "BatchMode=yes", "-i", private_key_path]


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


class Config:
    def __init__(self, args, rtl):
        if args.instance_a_host:
            # Modo direto — usado pelo terraform apply (main.tf), valores já
            # interpolados pelo próprio Terraform, sem chamar `terraform output`.
            missing = [f for f in ("extra_hosts", "instance_a_private_ip", "caliper_a_workers",
                                    "caliper_b_workers", "s3_bucket", "aws_region", "rpc_url",
                                    "private_key_path")
                       if getattr(args, f) is None]
            if missing:
                print(f"ERRO: --instance-a-host foi passado, mas faltam: {missing}", file=sys.stderr)
                sys.exit(1)
            self.instance_a_host = args.instance_a_host
            self.instance_a_private_ip = args.instance_a_private_ip
            self.extra_hosts = args.extra_hosts
            self.caliper_a_workers = args.caliper_a_workers
            self.caliper_b_workers = args.caliper_b_workers
            self.s3_bucket = args.s3_bucket
            self.aws_region = args.aws_region
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
            self.s3_bucket = outputs["s3_data_bucket"]
            self.aws_region = outputs["aws_region"]
            self.rpc_url = outputs["rpc_url"]

        self.node_caliper_count = len(self.extra_hosts) + 1

        self.tps_list = args.tps_list if args.tps_list else rtl.TPS_LIST
        all_functions = list(rtl.BENCHMARK_FILES.keys())
        self.functions = args.functions if args.functions else all_functions
        for f in self.functions:
            if f not in rtl.BENCHMARK_FILES:
                print(f"ERRO: função '{f}' não existe em BENCHMARK_FILES ({all_functions})", file=sys.stderr)
                sys.exit(1)
        self.benchmark_files = {f: distributed_path(rtl.BENCHMARK_FILES[f]) for f in self.functions}

        self.get_txpool_pending_count = rtl.get_txpool_pending_count
        self.wait_txpool_drain = rtl.wait_txpool_drain


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
            cfg.wait_txpool_drain(cfg.rpc_url)
    print(f"❌ Nenhum resultado válido para {function_name} @ {tps} TPS após {max_retries} tentativas (modo distribuído).")


def parse_args():
    p = argparse.ArgumentParser(description="Varredura distribuída do Caliper (N instâncias, MQTT).")
    p.add_argument("--terraform-dir", default=str(TF_DIR_DEFAULT),
                    help="Usado só quando --instance-a-host não é passado (lê via 'terraform output -json').")
    p.add_argument("--caliper-repo-path", default=str(CALIPER_REPO_DEFAULT))
    p.add_argument("--private-key-path", default=None,
                    help="Caminho da chave SSH. Obrigatório em modo direto; opcional (override) em modo terraform-output.")

    direct = p.add_argument_group("modo direto (usado pelo terraform apply — evita 'terraform output' durante o apply)")
    direct.add_argument("--instance-a-host", default=None, help="IP público da instância A (manager).")
    direct.add_argument("--instance-a-private-ip", default=None, help="IP privado da instância A (broker MQTT).")
    direct.add_argument("--extra-hosts", nargs="*", default=None, help="IPs públicos das instâncias extras.")
    direct.add_argument("--caliper-a-workers", type=int, default=None)
    direct.add_argument("--caliper-b-workers", type=int, default=None)
    direct.add_argument("--s3-bucket", default=None)
    direct.add_argument("--aws-region", default=None)
    direct.add_argument("--rpc-url", default=None)

    p.add_argument("--functions", nargs="+", default=None)
    p.add_argument("--tps-list", nargs="+", type=int, default=None)
    p.add_argument("--max-retries", type=int, default=MAX_RETRIES_DEFAULT)
    p.add_argument("--retry-delay", type=int, default=RETRY_DELAY_DEFAULT)
    p.add_argument("--dry-run", action="store_true",
                    help="Imprime os comandos SSH que seriam executados, sem rodar nada de verdade.")
    return p.parse_args()


def main():
    args = parse_args()
    rtl = load_run_test_local(args.caliper_repo_path)
    cfg = Config(args, rtl)

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

    for benchmark_file in set(cfg.benchmark_files.values()):
        patch_workers_number(cfg, benchmark_file, total_workers, dry_run=args.dry_run)

    for function_name in cfg.functions:
        benchmark_file = cfg.benchmark_files[function_name]
        print(f"\n{'='*50}\n🚀 Iniciando testes para função: {function_name}\n{'='*50}")
        for tps in cfg.tps_list:
            run_round(cfg, function_name, benchmark_file, tps, args.max_retries, args.retry_delay, dry_run=args.dry_run)
            if not args.dry_run:
                time.sleep(10)
                cfg.wait_txpool_drain(cfg.rpc_url)

    print("\nVarredura distribuída concluída — extraindo CSVs e subindo pro S3...")
    extract_cmd = (f"CALIPER_ROOT={CALIPER_ROOT_REMOTE} S3_KEYS_BUCKET={cfg.s3_bucket} "
                    f"AWS_REGION={cfg.aws_region} bash /tmp/extract_and_upload_results.sh")
    ssh_run(cfg.instance_a_host, cfg.private_key_path, extract_cmd, timeout=300, dry_run=args.dry_run)


if __name__ == "__main__":
    main()
