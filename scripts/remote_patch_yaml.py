#!/usr/bin/env python3
"""Patcha um campo numérico de linha única (ex.: 'tps' ou 'number') num YAML do
Caliper, preservando a indentação original. Roda no lado remoto (instância A) via
SSH, chamado por scripts/run_distributed_sweep.py.

Só é necessário no modo distribuído: o orquestrador (run_distributed_sweep.py)
roda no laptop do operador, não na instância onde o YAML vive, então o patch
precisa ser feito via SSH. No modo single-instance isso já é feito localmente,
sem necessidade deste script, por update_tps_in_file() em run_test_local.py
(mesma lógica de regex, mas roda no mesmo host do arquivo).

Uso: python3 remote_patch_yaml.py <arquivo.yaml> <campo> <valor_inteiro>
"""
import re
import sys


def main():
    if len(sys.argv) != 4:
        print("Uso: remote_patch_yaml.py <arquivo> <campo> <valor>", file=sys.stderr)
        sys.exit(1)
    path, field, value = sys.argv[1], sys.argv[2], int(sys.argv[3])

    with open(path) as f:
        text = f.read()

    pattern = re.compile(rf'^(\s*){re.escape(field)}:\s*\d+', re.MULTILINE)
    new_text, n = pattern.subn(rf'\g<1>{field}: {value}', text)

    if n == 0:
        print(f"ERRO: campo '{field}' não encontrado em {path}", file=sys.stderr)
        sys.exit(1)

    with open(path, 'w') as f:
        f.write(new_text)

    print(f"OK: {field} = {value} em {path} ({n} ocorrência(s))")


if __name__ == "__main__":
    main()
