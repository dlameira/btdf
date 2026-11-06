#!/usr/bin/env bash
# Publica o commit atual na VPS (invisiblechest), no padrão dos projetos da Seiva:
#   git archive HEAD | ssh seiva-vps  →  extrai em /srv/<app>  →  docker compose up -d --build
# Coloque na raiz do repositório, ajuste a seção CONFIG e rode: ./deploy.sh
# Sempre pede confirmação antes de publicar.
# Modo estatico: no .gitattributes, marque com export-ignore o que NÃO deve ir para o site
#   (deploy.sh, .gitignore, .gitattributes, CLAUDE.md), senão fica acessível publicamente.
set -euo pipefail

# ===== CONFIG =====
SERVER="seiva-vps"            # apelido do ~/.ssh/config (usuário seiva, dono de /srv)
APP="btdf"                     # nome da pasta em /srv e do container
BRANCH="main"
MODO="estatico"               # "compose": app em Docker em /srv/$APP
                              # "estatico": arquivos servidos pelo Caddy em /data/$APP
PASTA_SITE="."                # modo estatico: pasta do repo com o site (ex.: "site")
URL="https://dani.garden/btdf/"                # opcional: endereço para conferir depois (ex.: https://exemplo.com.br)
# ==================

# 1. O que vai ao ar tem que ser exatamente o que está no GitHub
if [[ -n "$(git status --porcelain)" ]]; then
  echo "Há alterações não commitadas. Faça commit antes de publicar." >&2; exit 1
fi
[[ "$(git branch --show-current)" == "$BRANCH" ]] || { echo "Mude para a branch $BRANCH antes." >&2; exit 1; }
git fetch -q origin "$BRANCH"
if [[ "$(git rev-parse HEAD)" != "$(git rev-parse "origin/$BRANCH")" ]]; then
  echo "A branch local difere de origin/$BRANCH. Faça push (ou pull) primeiro." >&2; exit 1
fi

VERSAO="$(git log --oneline -1)"
echo "Publicar \"$VERSAO\" em $SERVER ($MODO: $APP)"
read -r -p "Continuar? [s/N] " ok
[[ "$ok" =~ ^[sS]$ ]] || { echo "Cancelado."; exit 0; }

# Registro do que foi publicado (fica no servidor junto com o app)
REGISTRO="$(git rev-parse HEAD) $(date -Is) $(git config user.name)"

if [[ "$MODO" == "compose" ]]; then
  # 2a. Guarda a versão anterior (sem .env e sem dados) e troca o código.
  #     .env, volumes e pastas ignoradas pelo git não são tocados.
  git archive HEAD | ssh "$SERVER" "set -e
    mkdir -p /srv/$APP /srv/deploy-anteriores
    tar -czf /srv/deploy-anteriores/$APP-\$(date +%Y%m%d-%H%M%S).tgz -C /srv/$APP --exclude=.env --exclude='.env.*' --exclude=node_modules --exclude=dados .2>/dev/null || true
    ls -1t /srv/deploy-anteriores/$APP-*.tgz 2>/dev/null | tail -n +6 | xargs -r rm
    tar -x -C /srv/$APP
    echo '$REGISTRO' >> /srv/$APP/.publicado
    cd /srv/$APP && docker compose up -d --build 2>&1 | tail -3"
  echo "Para voltar: ssh $SERVER 'ls -t /srv/deploy-anteriores/$APP-*.tgz | head -1' e extraia em /srv/$APP"

elif [[ "$MODO" == "estatico" ]]; then
  # 2b. Troca a pasta servida pelo Caddy de uma vez (sem site pela metade no ar)
  git archive HEAD "$PASTA_SITE" | ssh "$SERVER" "set -e
    t=\$(mktemp -d); trap 'rm -rf \$t' EXIT
    tar -x -C \$t
    src=\$t/$PASTA_SITE; [ -f \$src/index.html ] || { echo 'sem index.html, nada publicado' >&2; exit 1; }
    docker exec caddy sh -c 'rm -rf /data/$APP.novo && mkdir -p /data/$APP.novo'
    docker cp \$src/. caddy:/data/$APP.novo/
    docker exec caddy sh -c 'rm -rf /data/$APP.velho; [ -d /data/$APP ] && mv /data/$APP /data/$APP.velho; mv /data/$APP.novo /data/$APP'
    echo publicado"
  echo "Para voltar: ssh $SERVER \"docker exec caddy sh -c 'rm -rf /data/$APP && mv /data/$APP.velho /data/$APP'\""
else
  echo "MODO desconhecido: $MODO" >&2; exit 1
fi

# 3. Conferência rápida
if [[ -n "$URL" ]]; then
  sleep 3
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 "$URL" || true)
  echo "$URL respondeu $code"
fi
echo "publicado: $VERSAO"
