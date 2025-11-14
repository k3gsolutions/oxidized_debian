# Instalação automatizada do Oxidized em Docker (Debian)

Este repositório contém um script único (`install_oxidized_stack.sh`) que prepara o ambiente completo de backup de configurações de rede em servidores Debian 12/13:

- Instala Docker Engine + plugins oficiais.
- Sobe o Portainer Community Edition para administrar os containers via web.
- Provisiona diretórios, arquivos de configuração e o container do Oxidized (incluindo o mapeamento CSV com porta/usuário/senha e testes automáticos após a instalação).

> **Importante:** execute todo o processo como `root` (ou `sudo su -`). O script modifica `/etc/apt`, instala pacotes e cria `/etc/oxidized`.

## Pré-requisitos

- Servidor com Debian 12 (Bookworm) ou 13 (Trixie) atualizado.
- Acesso à internet para baixar pacotes Docker/Portainer/Oxidized.
- `curl`, `git` e `gpg` (instalados automaticamente caso não existam).

## Passo a passo rápido

```bash
# 1. Clonar o repositório
cd /opt
git clone https://github.com/k3gsolutions/oxidized_debian.git
cd oxidized_debian

# 2. Executar o instalador
sudo bash install_oxidized_stack.sh
```

Ao final, o script exibirá um resumo com os containers ativos e URLs:

- Portainer: `https://<IP_DO_SERVIDOR>:9443`
- Oxidized Web/API: `http://<IP_DO_SERVIDOR>:8888`

## O que o script faz internamente

1. **Validações iniciais** – exige root e garante que a distribuição é Debian.
2. **Docker** – instala dependências, adiciona o repositório oficial, habilita `docker` e `containerd` e valida com `docker run --rm hello-world`.
3. **Portainer** – cria o volume `portainer_data`, remove versões antigas do container (se existirem) e sobe `portainer/portainer-ce:latest` expondo as portas 8000/9443.
4. **Oxidized**
   - Cria `/etc/oxidized`, `/etc/oxidized/.oxidized`, `configs`, `logs` e `crash`.
   - Gera `config` com o mapeamento CSV completo (`name`, `ip`, `model`, `input`, `username`, `password`, `ssh_port`).
   - Cria um `router.db` de exemplo já no novo formato (descrição abaixo).
   - Provisiona o container `oxidized/oxidized:latest` com reinício automático e camada REST em `0.0.0.0:8888`.
5. **Validações** – consulta Portainer via HTTPS, Oxidized via `/nodes` e mostra um resumo com `docker ps` filtrando os serviços principais.

## Estrutura criada

```
/etc/oxidized/
├── config        # Arquivo principal do Oxidized
├── router.db     # Dispositivos gerenciados (CSV customizado)
├── configs/      # Saída (backups) do Oxidized
├── logs/
└── crash/
```

Os diretórios são bind mounts do container, portanto qualquer alteração local reflete imediatamente dentro do Oxidized.

## Formato do `router.db`

Cada linha segue o padrão abaixo, separado por dois-pontos (`:`):

```
nome_do_dispositivo:ip:modelo:input:usuario:senha:porta
```

Exemplo realista:

```
core-bra-01:138.219.128.1:vrp:ssh:keslley:#100784KyK_:50022
```

- `nome_do_dispositivo`: texto exibido na interface.
- `ip`: endereço usado para a conexão.
- `modelo`: qualquer modelo suportado (ex.: `ios`, `junos`, `vrp`, `nxos`).
- `input`: normalmente `ssh` (pode ser `telnet` para equipamentos legados).
- `usuario` / `senha`: credenciais utilizadas no login.
- `porta`: porta TCP do serviço (22, 50022, etc.).

Após editar o arquivo, escolha um dos métodos abaixo:

```bash
# Recarregar o inventário sem derrubar o container
curl -s -X POST http://localhost:8888/nodes/reload

# OU reiniciar o container
docker restart oxidized
```

> Atenção: o inventário **não deve conter colchetes ou aspas**; apenas os campos separados por dois-pontos. Se for necessário usar dois-pontos na senha, prefira mover as credenciais para o `config` (seção `groups` ou `vars`).

## Testes e monitoramento

- Verificar containers ativos: `docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'`.
- Logs do Oxidized: `docker logs -f oxidized`.
- Forçar coleta de um dispositivo: `curl -s http://localhost:8888/node/next/<nome>`.
- Exportar configuração atual (última versão): `curl -s http://localhost:8888/node/fetch/<nome>`.

Se o Oxidized retornar `no_connection`, valide manualmente o acesso SSH (porta, credenciais, ACLs) executando, a partir do host:

```bash
ssh -p <porta> <usuario>@<ip>
```

## Atualizações futuras

- Para atualizar o Oxidized ou Portainer, basta executar novamente o script (ele remove containers anteriores mantendo os dados) ou rodar `docker pull` seguido de `docker restart`.
- Como boas práticas, mantenha o Debian atualizado (`apt update && apt upgrade`) e faça backup periódico de `/etc/oxidized`.

---

Com isso, você terá um ambiente consistente e reproduzível para coletar backups de configurações de rede usando Docker, Portainer e Oxidized. Dúvidas ou sugestões podem ser abertas via issues no próprio repositório.
