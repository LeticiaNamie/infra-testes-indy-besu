# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this project does

This is a Terraform project that automates end-to-end performance testing of Hyperledger Besu smart contracts. A single `terraform apply` provisions an AWS EC2 instance and runs the full pipeline in three sequential stages:

1. **Etapa 1** — Provisions the EC2 instance and boots a permissioned 6-node Besu QBFT network inside Docker Compose, configured dynamically using the instance's own private IP.
2. **Etapa 2** — Deploys Indy DID Registry smart contracts (IndyDidRegistry, CredentialDefinitionRegistry, SchemaRegistry, RevocationRegistry) via Hardhat Ignition using the Node-1 private key.
3. **Etapa 3** — Runs Hyperledger Caliper benchmark tests, extracts CSV reports, and uploads them to an S3 bucket.

## Commands

### Terraform lifecycle

```bash
# First-time: initialize providers
terraform init

# Preview changes
terraform plan

# Deploy everything (runs all three stages end-to-end; takes ~15–25 minutes)
terraform apply

# Tear down all AWS resources
terraform destroy
```

### SSH access (after apply)

```bash
# Get the instance IP and SSH command from outputs
terraform output ssh_command
terraform output rpc_url

# Follow the setup log in real time
ssh -i ~/.ssh/besu-key ubuntu@<IP> 'tail -f /var/log/besu-setup.log'

# Check network-info and deployed contract addresses (after Etapa 2)
ssh -i ~/.ssh/besu-key ubuntu@<IP> 'cat /home/ubuntu/deploy-artifacts/network-info.json'
ssh -i ~/.ssh/besu-key ubuntu@<IP> 'ls /home/ubuntu/deploy-artifacts/deployments/'

# Check S3 for Caliper CSV results (after Etapa 3)
aws s3 ls s3://$(terraform output -raw s3_bucket_name)/ --recursive
```

### Validate the Besu network manually

```bash
curl -X POST \
  --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
  http://<EIP>:8545
```

## Architecture

### Terraform dependency chain

```
aws_eip → null_resource.wait_besu_ready → null_resource.deploy_contracts → null_resource.run_caliper_tests
```

The `wait_besu_ready` resource polls SSH and then the Besu RPC endpoint before moving on — this is the mechanism that serializes Etapa 1 → Etapa 2 → Etapa 3 without any manual steps.

### EC2 setup (scripts/user_data.sh)

Runs as root on first boot. Key actions in order:
- Installs Docker, clones `jeffsonsousa/besu-production-docker` (branch `develop`)
- Downloads JDK 21 and Besu 24.7.0 into the repo root (required by `Dockerfile COPY` directives)
- Runs `besu operator generate-blockchain-config` to generate node keys and genesis
- Rewrites `permissions_config.toml` and `static-nodes.json` in all 6 `Node-X/data/` directories with the actual EC2 private IP (obtained from instance metadata at `169.254.169.254`)
- Patches `docker-compose.yaml`: inserts bootnode enodes for Node-1 and Node-3, and fixes the `besu-image-local:2.0` → `1.0` tag mismatch
- Builds the local Docker image and runs `docker compose up -d`

### Smart contract deploy (scripts/deploy_contracts.sh)

Runs on the EC2 instance via `remote-exec`. Key actions:
- Installs Node.js 18, clones `jeffsonsousa/contracts-indy-besu`
- Dynamically fetches `chainId` from the running Besu network and reads Node-1's private key to generate `hardhat.config.ts`
- Compiles and deploys via `npx hardhat ignition deploy ./ignition/modules/DeployAndInitializeContracts.ts --network local`
- Saves `network-info.json` and copies the Ignition deployment journal to `/home/ubuntu/deploy-artifacts/`

### Caliper test execution (scripts/run_caliper_tests.sh)

Runs on the EC2 instance via `remote-exec`. Key actions:
- Clones `LeticiaNamie/tests-with-caliper` (contains Caliper workspace at `evaluation-contracts-indy-besu/`)
- Installs `@hyperledger/caliper-cli@0.5.0` and binds it to `besu:latest`
- Patches `networkconfig.json` with deployed contract addresses, chainId, fromAddress, and private key from the Etapa 2 artifacts; also fixes the WebSocket port (8546 → 8645)
- Runs `python3 run_test_local.py`, then `extract_report_to_csv.py` and `extract_resource_to_csv.py`
- Uploads all CSVs to S3 under a timestamped prefix

### Required AWS infrastructure

- EC2 instance (`m5.2xlarge` as configured in `terraform.tfvars`)
- Elastic IP (static public IP)
- Security Group: ports 22 (SSH, restricted), 8545/8546 (RPC/WS), 30303 (P2P), 9545 (Prometheus)
- S3 bucket named `tests-with-caliper-results-<account-id>` with an IAM role/instance profile granting `s3:PutObject`
- SSH key pair using `~/.ssh/besu-key.pub` — this key must exist locally before `terraform apply`

### Variables

Set in `terraform.tfvars` (not committed with secrets). The only required variable without a default is `allowed_ssh_cidr`. Key variables:

| Variable | Default | Purpose |
|---|---|---|
| `allowed_ssh_cidr` | — | Restricts SSH to a specific IP/CIDR |
| `private_key_path` | `~/.ssh/id_rsa` | Path to SSH private key for `remote-exec` |
| `instance_type` | `m6i.2xlarge` | EC2 instance size |
| `project_name` | `besu-etapa1` | Prefix for all AWS resource names |

### Key file paths on the EC2 instance

| Path | Purpose |
|---|---|
| `/var/log/besu-setup.log` | Unified log for all three stages |
| `/home/ubuntu/besu-production-docker/` | Besu Docker repo (6-node QBFT network) |
| `/home/ubuntu/besu-production-docker/Permissioned-Network/Node-1/data/key` | Node-1 private key (used for contract deploy and Caliper) |
| `/home/ubuntu/contracts-indy-besu/` | Hardhat project with Indy contracts |
| `/home/ubuntu/deploy-artifacts/` | Ignition deployment journal + `network-info.json` |
| `/home/ubuntu/tests-with-caliper/evaluation-contracts-indy-besu/` | Caliper workspace |