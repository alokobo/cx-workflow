#!/usr/bin/env bash
# =====================================================================================================
# cleanup.sh — siempre se ejecuta (if: always()): secretos fuera del disco y repo restaurado
# =====================================================================================================
# Las caches (Maven/Gradle/pip/npm/NuGet/Go) se CONSERVAN: son las que hacen rapida la siguiente corrida.
set -uo pipefail
CX_STEP=cleanup
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
state_load

# 1. restaurar manifiestos reescritos si resolve.sh murio antes de su trap
if [[ -f "${CX_WORK}/backup/restore.list" ]]; then
	while IFS=$'\t' read -r b f; do [[ -f "${b}" ]] && cp -p "${b}" "${f}"; done < "${CX_WORK}/backup/restore.list"
fi
# 2. configuracion generada dentro del repo
[[ -n "${CFG_DIR_GENERATED:-}" && -f "${CFG_DIR_GENERATED}/.cx-one-generated" ]] && rm -rf "${CFG_DIR_GENERATED}"
# 3. unico archivo con secreto
[[ -n "${NETRC_FILE:-}" ]] && rm -f "${NETRC_FILE}"
rm -rf "${CX_WORK}/backup"
log "Limpieza completada (credenciales y configuracion temporal eliminadas; caches conservadas)"
exit 0
