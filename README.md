# infra-testes-indy-besu

Este diretório contém a configuração Terraform para criar uma instância EC2 Ubuntu 22.04 `t3.medium` e executar um container Hyperledger Besu.

## Como usar

1. Configure suas credenciais AWS no ambiente.
2. Execute:
   - `terraform init`
   - `terraform validate`
   - `terraform apply -auto-approve`
3. Após o deploy, exporte os outputs com `terraform output`.

## Evidências

O Terraform já foi inicializado com sucesso e a configuração foi validada:
- `terraform init` retornou "Terraform has been successfully initialized!"
- `terraform validate` retornou "Success! The configuration is valid."

## Validação do Besu

O script de inicialização na instância grava o resultado do container Besu em:
- `/var/log/besu-startup.log`
- `/var/log/besu-startup-error.log` (em caso de erro)

Para verificar se o comando Docker funcionou, conecte-se à instância via SSH e leia o arquivo:

```bash
cat /var/log/besu-startup.log
```

Se o Besu iniciou corretamente, o arquivo conterá uma mensagem de sucesso.
