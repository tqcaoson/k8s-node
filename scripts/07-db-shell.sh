#!/usr/bin/env bash
# Mo shell MySQL vao PXC (Pod cluster1-pxc-0) voi quyen root.
#   ./scripts/07-db-shell.sh                          # shell tuong tac
#   ./scripts/07-db-shell.sh "SELECT * FROM tasks;"  # chay 1 lenh
# Trong shell, database mac dinh la appdb. VD:
#   SHOW TABLES;  SELECT * FROM tasks;  SHOW STATUS LIKE 'wsrep_cluster_size';
set -euo pipefail
source "$(dirname "$0")/common.sh"

need_cmd kubectl
if [ $# -gt 0 ]; then
  kubectl -n production exec -it cluster1-pxc-0 -c pxc -- mysql -uroot -p'PxcRoot123!' appdb -e "$*"
else
  kubectl -n production exec -it cluster1-pxc-0 -c pxc -- mysql -uroot -p'PxcRoot123!' appdb
fi
