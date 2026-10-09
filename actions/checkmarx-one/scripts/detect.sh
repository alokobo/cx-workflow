#!/usr/bin/env bash
# =====================================================================================================
# detect.sh — UNA sola pasada por el arbol: ecosistemas, toolchains requeridos, cobertura de lockfiles
#             y huella (fingerprint) de todo lo que influye en la resolucion de dependencias.
# =====================================================================================================
# Reemplaza las N detecciones por ecosistema (toolchain.sh/auth.sh/resolve.sh x lenguaje) por un unico
# find con poda. Todo lo demas (configure/resolve/scan) lee CX_STATE; nadie vuelve a recorrer el repo.
#
# Salidas (GITHUB_OUTPUT y CX_STATE):
#   ecosystems            csv de ecosistemas detectados (maven,gradle,npm,yarn,pnpm,python,poetry,uv,nuget,go,...)
#   sca_present           true si hay algun manifiesto soportado por ScaResolver
#   need_java/need_maven/need_gradle/need_node/need_yarn/need_python/need_poetry/need_uv/need_dotnet/need_go
#   fingerprint           sha256 de manifiestos + lockfiles + config de gestores + parametros de resolucion
#   unlocked              ecosistemas con manifiestos SIN lockfile (resolucion con red -> mas lenta / no determinista)
# =====================================================================================================
set -Eeuo pipefail
CX_STEP=detect
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SOURCE_DIR="$(cd "${SOURCE_DIR:-.}" && pwd)"
EXTRA_PRUNE="${CX_EXCLUDE_DIRS:-}"     # csv adicional (input exclude-dirs)

# Directorios que nunca contienen manifiestos "fuente" (salidas de build, deps instaladas, IDE, VCS).
PRUNE=(.git .hg .svn node_modules bower_components jspm_packages .venv venv env .env __pycache__ site-packages
       .tox .nox .eggs .mypy_cache .pytest_cache dist target .gradle .idea .vscode .vs obj Pods vendor
       .terraform .next .nuxt .angular .svelte-kit coverage .cxsca.configurations .cx-one)
IFS=',' read -r -a extra <<< "${EXTRA_PRUNE}"
for d in "${extra[@]}"; do d="${d//[[:space:]]/}"; [[ -n "${d}" ]] && PRUNE+=("${d}"); done

# Archivos que ScaResolver usa (doc "Files Used for Manifest Resolution") + configuracion de gestores
NAMES=(pom.xml build.gradle build.gradle.kts settings.gradle settings.gradle.kts gradle.properties
       gradle-wrapper.properties libs.versions.toml gradle.lockfile gradlew
       package.json package-lock.json npm-shrinkwrap.json yarn.lock pnpm-lock.yaml lerna.json bower.json
       .npmrc .yarnrc .yarnrc.yml
       'requirements*.txt' 'requirement*.txt' packages.txt pyproject.toml poetry.lock uv.lock Pipfile Pipfile.lock
       setup.py setup.cfg
       '*.csproj' '*.vbproj' '*.fsproj' packages.config packages.lock.json project.assets.json nuget.config
       NuGet.Config global.json Directory.Packages.props Directory.Build.props
       go.mod go.sum composer.json composer.lock Gemfile Gemfile.lock gemfile gemfile.lock
       Podfile Podfile.lock Package.swift Package.resolved Cartfile Cartfile.private Cartfile.resolved
       build.sbt plugins.sbt ivy.xml cpanfile cpanfile.snapshot pubspec.lock settings.xml)

prune_expr=(); for d in "${PRUNE[@]}"; do prune_expr+=(-name "${d}" -o); done; unset 'prune_expr[${#prune_expr[@]}-1]'
name_expr=();  for n in "${NAMES[@]}"; do name_expr+=(-name "${n}" -o); done;  unset 'name_expr[${#name_expr[@]}-1]'

LIST="${CX_WORK}/manifests.list"
find "${SOURCE_DIR}" \( -type d \( "${prune_expr[@]}" \) -prune \) -o \( -type f \( "${name_expr[@]}" \) -print \) \
	2>/dev/null | LC_ALL=C sort > "${LIST}"

count() { grep -cE "$1" "${LIST}" || true; }
has()   { grep -qE "$1" "${LIST}"; }
dirs_of() { grep -E "$1" "${LIST}" | xargs -r -n1 -d '\n' dirname | LC_ALL=C sort -u; }

declare -A NEED=()
ECOS=(); UNLOCKED=()

# ---------------------------------------------------------------- Java
if has '/pom\.xml$'; then
	ECOS+=(maven); NEED[java]=1; NEED[maven]=1
fi
if has '/build\.gradle(\.kts)?$'; then
	ECOS+=(gradle); NEED[java]=1
	has '/gradlew$' || NEED[gradle]=1                      # sin wrapper -> gradle del sistema
	has '/gradle\.lockfile$' || UNLOCKED+=(gradle)
fi
has '/(build\.sbt|ivy\.xml)$' && { ECOS+=(sbt-ivy); NEED[java]=1; }

# ---------------------------------------------------------------- JavaScript
if has '/package\.json$'; then
	NEED[node]=1
	if has '/yarn\.lock$'; then ECOS+=(yarn); NEED[yarn]=1; fi
	if has '/pnpm-lock\.yaml$'; then ECOS+=(pnpm); fi
	if has '/(package-lock|npm-shrinkwrap)\.json$' || ! has '/(yarn\.lock|pnpm-lock\.yaml)$'; then ECOS+=(npm); fi
	# package.json "raiz" sin ningun lockfile en su directorio -> npm hara --package-lock-only contra el registry
	while IFS= read -r d; do
		[[ -f "${d}/package-lock.json" || -f "${d}/npm-shrinkwrap.json" || -f "${d}/yarn.lock" || -f "${d}/pnpm-lock.yaml" ]] && continue
		# subpaquete de un workspace: el lockfile vive en un ancestro
		p="${d}"; locked=false
		while [[ "${p}" != "${SOURCE_DIR}" && "${p}" != "/" ]]; do
			p="$(dirname "${p}")"
			[[ -f "${p}/package-lock.json" || -f "${p}/yarn.lock" || -f "${p}/pnpm-lock.yaml" ]] && { locked=true; break; }
		done
		[[ "${locked}" == false ]] && { UNLOCKED+=("npm:$(rel "${d}")"); }
	done < <(dirs_of '/package\.json$')
fi
has '/bower\.json$' && { ECOS+=(bower); NEED[node]=1; }

# ---------------------------------------------------------------- Python
if has '/(requirements?[^/]*\.txt|packages\.txt|setup\.py|setup\.cfg)$'; then
	ECOS+=(pip); NEED[python]=1; UNLOCKED+=(pip)          # pip siempre instala en un virtualenv temporal
fi
if has '/pyproject\.toml$'; then
	if has '/poetry\.lock$'; then ECOS+=(poetry); NEED[python]=1; NEED[poetry]=1
	elif has '/uv\.lock$';   then ECOS+=(uv); NEED[python]=1; NEED[uv]=1
	else ECOS+=(pip); NEED[python]=1; fi
fi
has '/Pipfile(\.lock)?$' && { ECOS+=(pipenv); NEED[python]=1; }

# ---------------------------------------------------------------- .NET / Go / PHP / Ruby / Apple / otros
if has '/([^/]+\.(cs|vb|fs)proj|packages\.config)$'; then
	ECOS+=(nuget); NEED[dotnet]=1
	has '/packages\.lock\.json$' || UNLOCKED+=(nuget)
fi
if has '/go\.mod$'; then ECOS+=(go); NEED[go]=1; has '/go\.sum$' || UNLOCKED+=(go); fi
if has '/composer\.json$'; then ECOS+=(composer); NEED[composer]=1; has '/composer\.lock$' || UNLOCKED+=(composer); fi
if has '/[Gg]emfile$'; then ECOS+=(rubygems); has '/[Gg]emfile\.lock$' || { NEED[bundler]=1; UNLOCKED+=(rubygems); }; fi
has '/Podfile$' && { ECOS+=(cocoapods); has '/Podfile\.lock$' || UNLOCKED+=(cocoapods); }
has '/Package\.(swift|resolved)$' && ECOS+=(swiftpm)
has '/Cartfile' && ECOS+=(carthage)
has '/cpanfile$' && ECOS+=(cpan)
has '/pubspec\.lock$' && ECOS+=(pub)

mapfile -t ECOS < <(printf '%s\n' "${ECOS[@]:-}" | awk 'NF && !seen[$0]++')
SCA_PRESENT=false; [[ ${#ECOS[@]} -gt 0 ]] && SCA_PRESENT=true

# ---------------------------------------------------------------- fingerprint (todo lo que cambia la resolucion)
# Contenido de cada archivo + ruta relativa + parametros que alteran el resultado (CX_FP_EXTRA lo arma action.yml:
# version de ScaResolver, parametros, URLs de Artifactory, ttl bucket). Una sola lectura de cada archivo.
FP_FILE="${CX_WORK}/fingerprint.src"
: > "${FP_FILE}"
while IFS= read -r f; do
	[[ "$(basename "${f}")" == "gradlew" ]] && continue
	printf '%s  %s\n' "$(sha256_of "${f}" | cut -d' ' -f1)" "$(rel "${f}")" >> "${FP_FILE}"
done < "${LIST}"
printf 'extra:%s\n' "${CX_FP_EXTRA:-}" >> "${FP_FILE}"
# TTL del resultado cacheado: manifiestos con rangos (^1.2, >=2.0) sin lockfile pueden resolver a versiones
# nuevas aunque el repo no cambie; el bucket temporal fuerza una re-resolucion periodica.
case "${CX_RESULT_TTL:-weekly}" in
	daily)   bucket="$(date -u +%Y%m%d)" ;;
	weekly)  bucket="$(date -u +%G-W%V)" ;;
	monthly) bucket="$(date -u +%Y-%m)" ;;
	*)       bucket="none" ;;
esac
printf 'ttl:%s\n' "${bucket}" >> "${FP_FILE}"
FINGERPRINT="$(sha256_of "${FP_FILE}" | cut -d' ' -f1)"

# ---------------------------------------------------------------- salida
csv() { local IFS=,; echo "$*"; }
ECOS_CSV="$(csv "${ECOS[@]:-}")"
UNLOCKED_CSV="$(csv "${UNLOCKED[@]:-}")"

state_set SOURCE_DIR "${SOURCE_DIR}"
state_set ECOSYSTEMS "${ECOS_CSV}"
state_set SCA_PRESENT "${SCA_PRESENT}"
state_set FINGERPRINT "${FINGERPRINT}"
set_output ecosystems "${ECOS_CSV}"
set_output sca_present "${SCA_PRESENT}"
set_output fingerprint "${FINGERPRINT}"
set_output unlocked "${UNLOCKED_CSV}"
# Toolchain ya presente en el runner? (imagen corporativa con toolchains preinstalados = 0 descargas)
have_tool() {
	case "$1" in
		java)    command -v java >/dev/null 2>&1 ;;
		maven)   command -v mvn >/dev/null 2>&1 ;;
		gradle)  command -v gradle >/dev/null 2>&1 ;;
		node)    command -v node >/dev/null 2>&1 && command -v npm >/dev/null 2>&1 ;;
		yarn)    command -v yarn >/dev/null 2>&1 || command -v corepack >/dev/null 2>&1 ;;
		python)  command -v python3 >/dev/null 2>&1 && python3 -m pip --version >/dev/null 2>&1 ;;
		poetry)  command -v poetry >/dev/null 2>&1 ;;
		uv)      command -v uv >/dev/null 2>&1 ;;
		dotnet)  command -v dotnet >/dev/null 2>&1 ;;
		go)      command -v go >/dev/null 2>&1 ;;
		composer) command -v composer >/dev/null 2>&1 ;;
		bundler) command -v bundle >/dev/null 2>&1 ;;
	esac
}
NEEDED=(); MISSING=()
for t in java maven gradle node yarn python poetry uv dotnet go composer bundler; do
	v=false; h=false
	[[ -n "${NEED[${t}]:-}" ]] && { v=true; NEEDED+=("${t}"); }
	have_tool "${t}" && h=true
	[[ "${v}" == true && "${h}" == false ]] && MISSING+=("${t}")
	state_set "NEED_${t^^}" "${v}"
	set_output "need_${t}" "${v}"
	set_output "have_${t}" "${h}"
done
NEEDED_CSV="$(csv "${NEEDED[@]:-}")"; MISSING_CSV="$(csv "${MISSING[@]:-}")"

# Archivos de version para los setup-* (solo se usan si el toolchain falta en el runner)
first_of() { local f; for f in "$@"; do [[ -f "${SOURCE_DIR}/${f}" ]] && { echo "${SOURCE_DIR}/${f}"; return 0; }; done; echo ""; }
set_output node_version_file "$(first_of .nvmrc .node-version)"
set_output python_version_file "$(first_of .python-version)"
set_output java_version_file "$(first_of .java-version .sdkmanrc .tool-versions)"
set_output dotnet_global_json "$(first_of global.json)"
set_output go_mod_file "$(grep -m1 '/go\.mod$' "${LIST}" || true)"
state_set MISSING_TOOLS "${MISSING_CSV}"

total="$(wc -l < "${LIST}" | tr -d ' ')"
log "Archivos relevantes: ${total} · ecosistemas: ${ECOS_CSV:-<ninguno>} · toolchains: ${NEEDED_CSV:-<ninguno>} · faltan en el runner: ${MISSING_CSV:-<ninguno>}"
log "Fingerprint de resolucion: ${FINGERPRINT}"
if [[ -n "${UNLOCKED_CSV}" ]]; then
	warn "Manifiestos sin lockfile (${UNLOCKED_CSV}): ScaResolver tendra que consultar Artifactory para fijar versiones. Versionar lockfiles (package-lock.json, gradle.lockfile, packages.lock.json, go.sum, composer.lock, Gemfile.lock) hace la resolucion mas rapida y determinista."
fi
{
	echo "### Checkmarx One · deteccion"
	echo "| Ecosistemas | Toolchains requeridos | Faltan en el runner | Sin lockfile | Archivos |"
	echo "|---|---|---|---|---|"
	echo "| ${ECOS_CSV:-—} | ${NEEDED_CSV:-—} | ${MISSING_CSV:-—} | ${UNLOCKED_CSV:-—} | ${total} |"
} >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
