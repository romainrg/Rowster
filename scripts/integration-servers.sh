#!/usr/bin/env bash
# Starts or stops throwaway servers for `make integration`, all bound to 127.0.0.1 and stored under
# build/integration: PostgreSQL (port 54329, TLS, SCRAM and MD5 users), MySQL (port 33069, TLS) and
# an sshd running as the current user (port 22229, key authentication only).
# Usage: scripts/integration-servers.sh start|stop|status
# Requires: brew install postgresql@17 mysql. Nothing here is ever shipped, and the password is public.
set -euo pipefail
cd "$(dirname "$0")/.."

ROOT="$PWD/build/integration"
PASSWORD="rowster-test"
PG_PORT=54329
MYSQL_PORT=33069
MARIADB_PORT=33079
SSH_PORT=22229

brew_bin() { # brew_bin <formula...> : first existing bin directory
  for formula in "$@"; do
    if [[ -d "/opt/homebrew/opt/$formula/bin" ]]; then echo "/opt/homebrew/opt/$formula/bin"; return; fi
    if [[ -d "/usr/local/opt/$formula/bin" ]]; then echo "/usr/local/opt/$formula/bin"; return; fi
  done
}
PG_BIN="$(brew_bin postgresql@17 postgresql@18 postgresql@16 postgresql)"
MYSQL_BIN="$(brew_bin mysql)"

start_postgres() {
  [[ -n "$PG_BIN" ]] || { echo "postgres: not installed, skipped"; return; }
  local data="$ROOT/pg"
  if [[ ! -d "$data" ]]; then
    mkdir -p "$ROOT"
    printf '%s' "$PASSWORD" > "$ROOT/pwfile"
    "$PG_BIN/initdb" -D "$data" -U postgres --auth=scram-sha-256 --pwfile="$ROOT/pwfile" -E UTF8 >/dev/null
    rm "$ROOT/pwfile"
    openssl req -new -x509 -days 3650 -nodes -subj "/CN=localhost" \
      -addext "subjectAltName=DNS:localhost,IP:127.0.0.1" \
      -keyout "$data/server.key" -out "$data/server.crt" 2>/dev/null
    chmod 600 "$data/server.key"
    cat >> "$data/postgresql.conf" <<EOF
port = $PG_PORT
listen_addresses = '127.0.0.1'
unix_socket_directories = '$ROOT'
ssl = on
EOF
    cat > "$data/pg_hba.conf" <<EOF
local   all all                         scram-sha-256
host    all rowster_md5   127.0.0.1/32  md5
hostssl all rowster_tls   127.0.0.1/32  scram-sha-256
hostnossl all rowster_tls 127.0.0.1/32  reject
host    all all           127.0.0.1/32  scram-sha-256
EOF
  fi
  if ! "$PG_BIN/pg_ctl" -D "$data" status >/dev/null 2>&1; then
    "$PG_BIN/pg_ctl" -D "$data" -l "$ROOT/pg.log" -w start >/dev/null
  fi
  PGPASSWORD="$PASSWORD" "$PG_BIN/psql" -h 127.0.0.1 -p "$PG_PORT" -U postgres -v ON_ERROR_STOP=1 -q postgres <<EOF
DO \$\$ BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'rowster') THEN
    CREATE ROLE rowster LOGIN SUPERUSER PASSWORD '$PASSWORD';
    CREATE ROLE rowster_tls LOGIN PASSWORD '$PASSWORD';
    SET password_encryption = 'md5';
    CREATE ROLE rowster_md5 LOGIN PASSWORD '$PASSWORD';
  END IF;
END \$\$;
SELECT 'CREATE DATABASE rowster_test OWNER rowster'
  WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'rowster_test') \gexec
EOF
  echo "postgres: 127.0.0.1:$PG_PORT (users rowster, rowster_tls, rowster_md5; database rowster_test)"
}

start_mysql() {
  [[ -n "$MYSQL_BIN" ]] || { echo "mysql: not installed, skipped"; return; }
  local data="$ROOT/mysql"
  local fresh=0
  if [[ ! -d "$data" ]]; then
    mkdir -p "$ROOT"
    "$MYSQL_BIN/mysqld" --no-defaults --initialize-insecure --datadir="$data" >/dev/null 2>&1
    fresh=1
  fi
  if ! "$MYSQL_BIN/mysqladmin" --no-defaults -S "$ROOT/mysql.sock" -u root ping >/dev/null 2>&1; then
    "$MYSQL_BIN/mysqld" --no-defaults --datadir="$data" --port="$MYSQL_PORT" --bind-address=127.0.0.1 \
      --socket="$ROOT/mysql.sock" --mysqlx=OFF --pid-file="$ROOT/mysql.pid" \
      --log-error="$ROOT/mysql.log" >/dev/null 2>&1 &
    for _ in $(seq 1 60); do
      "$MYSQL_BIN/mysqladmin" --no-defaults -S "$ROOT/mysql.sock" -u root ping >/dev/null 2>&1 && break
      sleep 0.5
    done
  fi
  if [[ $fresh == 1 ]]; then
    "$MYSQL_BIN/mysql" --no-defaults -S "$ROOT/mysql.sock" -u root <<EOF
CREATE DATABASE IF NOT EXISTS rowster_test CHARACTER SET utf8mb4;
CREATE USER IF NOT EXISTS 'rowster'@'127.0.0.1' IDENTIFIED BY '$PASSWORD';
CREATE USER IF NOT EXISTS 'rowster'@'localhost' IDENTIFIED BY '$PASSWORD';
GRANT ALL ON *.* TO 'rowster'@'127.0.0.1';
GRANT ALL ON *.* TO 'rowster'@'localhost';
CREATE USER IF NOT EXISTS 'rowster_tls'@'127.0.0.1' IDENTIFIED BY '$PASSWORD' REQUIRE SSL;
GRANT ALL ON rowster_test.* TO 'rowster_tls'@'127.0.0.1';
EOF
  fi
  echo "mysql: 127.0.0.1:$MYSQL_PORT (users rowster, rowster_tls; database rowster_test)"
}

start_mariadb() {
  local bin
  bin="$(brew_bin mariadb)"
  [[ -n "$bin" ]] || { echo "mariadb: not installed, skipped"; return; }
  local data="$ROOT/mariadb"
  local fresh=0
  if [[ ! -d "$data" ]]; then
    mkdir -p "$ROOT"
    "$bin/mariadb-install-db" --no-defaults --datadir="$data" --auth-root-authentication-method=normal >/dev/null 2>&1
    openssl req -new -x509 -days 3650 -nodes -subj "/CN=localhost" \
      -keyout "$data/server-key.pem" -out "$data/server-cert.pem" 2>/dev/null
    fresh=1
  fi
  if ! "$bin/mariadb-admin" --no-defaults -S "$ROOT/mariadb.sock" -u root ping >/dev/null 2>&1; then
    "$bin/mariadbd" --no-defaults --datadir="$data" --port="$MARIADB_PORT" --bind-address=127.0.0.1 \
      --socket="$ROOT/mariadb.sock" --pid-file="$ROOT/mariadb.pid" --log-error="$ROOT/mariadb.log" \
      --ssl-cert="$data/server-cert.pem" --ssl-key="$data/server-key.pem" >/dev/null 2>&1 &
    for _ in $(seq 1 60); do
      "$bin/mariadb-admin" --no-defaults -S "$ROOT/mariadb.sock" -u root ping >/dev/null 2>&1 && break
      sleep 0.5
    done
  fi
  if [[ $fresh == 1 ]]; then
    "$bin/mariadb" --no-defaults -S "$ROOT/mariadb.sock" -u root <<EOF
CREATE DATABASE IF NOT EXISTS rowster_test CHARACTER SET utf8mb4;
CREATE USER IF NOT EXISTS 'rowster'@'127.0.0.1' IDENTIFIED BY '$PASSWORD';
CREATE USER IF NOT EXISTS 'rowster'@'localhost' IDENTIFIED BY '$PASSWORD';
GRANT ALL ON *.* TO 'rowster'@'127.0.0.1';
GRANT ALL ON *.* TO 'rowster'@'localhost';
EOF
  fi
  echo "mariadb: 127.0.0.1:$MARIADB_PORT (user rowster; database rowster_test)"
}

start_sshd() {
  local dir="$ROOT/ssh"
  if [[ ! -d "$dir" ]]; then
    mkdir -p "$dir"
    ssh-keygen -q -t ed25519 -N "" -f "$dir/host_key"
    ssh-keygen -q -t ed25519 -N "" -f "$dir/id_ed25519"
    ssh-keygen -q -t ed25519 -N "$PASSWORD" -f "$dir/id_passphrase"
    cat "$dir/id_ed25519.pub" "$dir/id_passphrase.pub" > "$dir/authorized_keys"
    chmod 600 "$dir/authorized_keys"
    cat > "$dir/sshd_config" <<EOF
Port $SSH_PORT
ListenAddress 127.0.0.1
HostKey $dir/host_key
PidFile $dir/sshd.pid
AuthorizedKeysFile $dir/authorized_keys
PasswordAuthentication no
KbdInteractiveAuthentication no
UsePAM no
StrictModes no
AllowTcpForwarding yes
AllowStreamLocalForwarding yes
EOF
  fi
  if [[ ! -f "$dir/sshd.pid" ]] || ! kill -0 "$(cat "$dir/sshd.pid")" 2>/dev/null; then
    /usr/sbin/sshd -f "$dir/sshd_config" -E "$ROOT/sshd.log"
  fi
  echo "sshd: 127.0.0.1:$SSH_PORT (user $USER, keys in $dir)"
}

stop_all() {
  [[ -n "$PG_BIN" && -d "$ROOT/pg" ]] && "$PG_BIN/pg_ctl" -D "$ROOT/pg" -m fast stop >/dev/null 2>&1 || true
  [[ -f "$ROOT/mysql.pid" ]] && kill "$(cat "$ROOT/mysql.pid")" 2>/dev/null || true
  [[ -f "$ROOT/mariadb.pid" ]] && kill "$(cat "$ROOT/mariadb.pid")" 2>/dev/null || true
  [[ -f "$ROOT/ssh/sshd.pid" ]] && kill "$(cat "$ROOT/ssh/sshd.pid")" 2>/dev/null || true
  echo "stopped"
}

case "${1:-}" in
  start) start_postgres; start_mysql; start_mariadb; start_sshd ;;
  stop) stop_all ;;
  status)
    [[ -n "$PG_BIN" ]] && "$PG_BIN/pg_isready" -h 127.0.0.1 -p "$PG_PORT" || true
    [[ -n "$MYSQL_BIN" ]] && "$MYSQL_BIN/mysqladmin" --no-defaults -S "$ROOT/mysql.sock" -u root ping 2>&1 || true
    [[ -f "$ROOT/ssh/sshd.pid" ]] && kill -0 "$(cat "$ROOT/ssh/sshd.pid")" 2>/dev/null && echo "sshd is running" || echo "sshd is stopped"
    ;;
  *) echo "usage: $0 start|stop|status" >&2; exit 2 ;;
esac
