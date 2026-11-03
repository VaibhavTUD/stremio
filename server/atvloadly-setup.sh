#!/usr/bin/env bash
# One-time setup of atvloadly on a Debian/Ubuntu server.
#
# Installs Avahi and Docker, starts the atvloadly container (restarts with the server), and adds a
# daily systemd timer that pulls a newer image and recreates the container only when one exists.
# Safe to run again. Data lives in /srv/atvloadly and survives updates.
#
#   curl -fsSL https://raw.githubusercontent.com/VaibhavTUD/stremio/main/server/atvloadly-setup.sh | sudo bash
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "Run as root: sudo bash $0" >&2; exit 1; }
command -v apt-get >/dev/null || { echo "Needs a Debian/Ubuntu server (apt-get)." >&2; exit 1; }

IMAGE=bitxeno/atvloadly:latest
NAME=atvloadly
DATA=/srv/atvloadly
PORT=5533

export DEBIAN_FRONTEND=noninteractive
apt-get update -q
apt-get install -y -q avahi-daemon curl
command -v docker >/dev/null || apt-get install -y -q docker.io
systemctl enable --now avahi-daemon docker
install -d "$DATA"

cat >/usr/local/bin/atvloadly-update <<EOF
#!/usr/bin/env bash
# Pulls the newest atvloadly image; recreates the container only when the image changed.
set -euo pipefail
docker pull -q $IMAGE >/dev/null
want=\$(docker image inspect -f '{{.Id}}' $IMAGE)
have=\$(docker inspect -f '{{.Image}}' $NAME 2>/dev/null || true)
[ "\$want" = "\$have" ] && [ "\$(docker inspect -f '{{.State.Running}}' $NAME)" = true ] && exit 0
docker rm -f $NAME >/dev/null 2>&1 || true
docker run -d --name=$NAME --restart=always --security-opt seccomp:unconfined \\
  -p $PORT:80 -v $DATA:/data -v /var/run/dbus:/var/run/dbus \\
  -v /var/run/avahi-daemon:/var/run/avahi-daemon $IMAGE >/dev/null
if [ -n "\$have" ] && [ "\$have" != "\$want" ]; then docker rmi "\$have" >/dev/null 2>&1 || true; fi
echo "atvloadly running on image \$want"
EOF
chmod 755 /usr/local/bin/atvloadly-update

cat >/etc/systemd/system/atvloadly-update.service <<'EOF'
[Unit]
Description=Update the atvloadly container
Wants=network-online.target
After=network-online.target docker.service avahi-daemon.service
Requires=docker.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/atvloadly-update
EOF

cat >/etc/systemd/system/atvloadly-update.timer <<'EOF'
[Unit]
Description=Daily atvloadly update check

[Timer]
OnCalendar=*-*-* 04:30
RandomizedDelaySec=30m
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now atvloadly-update.timer
/usr/local/bin/atvloadly-update

echo
echo "Done. Open http://$(hostname -I | awk '{print $1}'):$PORT"
echo "Update log: journalctl -u atvloadly-update"
