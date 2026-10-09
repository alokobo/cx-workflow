#!/usr/bin/env bash
# =====================================================================================================
# lib.sh — utilidades comunes (se carga con "source"; no ejecutar directamente)
# =====================================================================================================
# Convenciones de todo el pipeline:
#   SOURCE_DIR   raiz del codigo a escanear (absoluta)
#   CX_WORK      directorio de trabajo FUERA del workspace ($RUNNER_TEMP/cx-one): nunca entra al zip de cx
#   CX_TOOLS     binarios cacheados (cx, ScaResolver, maven/gradle portables)
#   CX_STATE     archivo key=value con el resultado de detect.sh (lo leen los demas scripts)
# Ningun script escribe credenciales en disco salvo el .netrc (chmod 600, en CX_WORK, borrado en cleanup).
# =====================================================================================================

: "${RUNNER_TEMP:=/tmp}"
: "${CX_WORK:=${RUNNER_TEMP}/cx-one}"
: "${CX_TOOLS:=${RUNNER_TOOL_CACHE:-${RUNNER_TEMP}}/cx-one-tools}"
: "${CX_STATE:=${CX_WORK}/state.env}"
mkdir -p "${CX_WORK}" "${CX_TOOLS}"

_tag() { printf '[cx-one][%s]' "${CX_STEP:-main}"; }
log()   { echo "$(_tag) $*"; }
warn()  { echo "::warning title=Checkmarx One (${CX_STEP:-main})::$*"; }
err()   { echo "::error title=Checkmarx One (${CX_STEP:-main})::$*" >&2; }
die()   { err "$*"; exit 1; }
group() { echo "::group::$(_tag) $*"; }
endgroup() { echo "::endgroup::"; }

is_true() { case "${1,,}" in true|1|yes|y|on) return 0 ;; *) return 1 ;; esac; }

# Entorno PRIVADO de la accion: NO se usa GITHUB_ENV/GITHUB_PATH para no contaminar los pasos posteriores
# del job que llama (p.ej. un "npm install" propio que heredaria nuestro NPM_CONFIG_USERCONFIG).
# Cada script hace state_load, que carga este archivo. Nunca contiene secretos (ver load_secret_env).
: "${CX_ENV_FILE:=${CX_WORK}/env.sh}"
set_env() {
	local name="$1" value="$2"
	export "${name}=${value}"
	printf 'export %s=%q\n' "${name}" "${value}" >> "${CX_ENV_FILE}"
	return 0
}
add_path() {
	local dir="$1"
	case ":${PATH}:" in *":${dir}:"*) ;; *) export PATH="${dir}:${PATH}" ;; esac
	# shellcheck disable=SC2016  # literal: se expande al cargar env.sh
	printf 'case ":${PATH}:" in *":%s:"*) ;; *) export PATH=%q:"${PATH}" ;; esac\n' "${dir}" "${dir}" >> "${CX_ENV_FILE}"
	return 0
}

# Secretos derivados: solo en memoria del proceso que los necesita (install-tools, resolve, scan modo cli).
# Entrada: ARTIFACTORY_USER / ARTIFACTORY_PASSWORD / ARTIFACTORY_TOKEN como env del step (desde secrets).
load_secret_env() {
	local u="${ARTIFACTORY_USER:-}" p="${ARTIFACTORY_PASSWORD:-${ARTIFACTORY_TOKEN:-}}" host
	# access token (bearer): vale aun sin usuario
	if [[ -n "${ARTIFACTORY_TOKEN:-}" ]]; then
		export YARN_NPM_AUTH_TOKEN="${ARTIFACTORY_TOKEN}" COREPACK_NPM_TOKEN="${ARTIFACTORY_TOKEN}"
	fi
	[[ -n "${u}" && -n "${p}" ]] || return 0
	export CX_ART_USER="${u}" CX_ART_PASS="${p}"                 # settings.xml ${env.*} / nuget %VAR% / init.gradle
	CX_NPM_AUTH="$(printf '%s:%s' "${u}" "${p}" | base64 | tr -d '\r\n')"
	export CX_NPM_AUTH YARN__AUTH="${CX_NPM_AUTH}" YARN_ALWAYS_AUTH=true   # yarn v1 (prefijo YARN_ no afecta a npm)
	mask "${CX_NPM_AUTH}"
	if [[ -z "${ARTIFACTORY_TOKEN:-}" ]]; then
		export YARN_NPM_AUTH_IDENT="${u}:${p}" YARN_NPM_ALWAYS_AUTH=true COREPACK_NPM_USERNAME="${u}" COREPACK_NPM_PASSWORD="${p}"
	fi
	export NuGetPackageSourceCredentials_cxartifactory="Username=${u};Password=${p}"
	if [[ -n "${ARTIFACTORY_URL:-}" ]]; then
		host="$(host_of "${ARTIFACTORY_URL}")"
		COMPOSER_AUTH="$(printf '{"http-basic":{"%s":{"username":"%s","password":"%s"}}}' "${host}" "${u}" "${p}")"; export COMPOSER_AUTH
		# Bundler: "." -> "__", "-" -> "___"
		export "BUNDLE_$(echo "${host}" | sed -e 's/-/___/g' -e 's/\./__/g' | tr '[:lower:]' '[:upper:]')=${u}:${p}"
		[[ -n "${CX_GRADLE_DIST_BASE_URL:-}" ]] && export GRADLE_OPTS="${GRADLE_OPTS:-} -Dgradle.wrapperUser=${u} -Dgradle.wrapperPassword=${p}"
	fi
	return 0
}
# CA corporativa: bundle COMBINADO (raices del sistema + CA corporativa) para no reemplazar las raices
# publicas (SSL_CERT_FILE en Go/cx/OpenSSL reemplaza, no agrega). Mismo resultado en todos los caminos.
setup_ca() {
	[[ -n "${CX_CA_BUNDLE:-}" ]] || return 0
	[[ -f "${CX_CA_BUNDLE}" ]] || die "ca-bundle no existe: ${CX_CA_BUNDLE}"
	local combined="${CX_WORK}/ca-combined.pem" sys
	if [[ ! -s "${combined}" ]]; then
		for sys in /etc/ssl/certs/ca-certificates.crt /etc/pki/tls/certs/ca-bundle.crt /etc/ssl/cert.pem; do
			[[ -f "${sys}" ]] && { cat "${sys}" > "${combined}"; break; }
		done
		{ echo; cat "${CX_CA_BUNDLE}"; } >> "${combined}"
	fi
	export SSL_CERT_FILE="${combined}" REQUESTS_CA_BUNDLE="${combined}" PIP_CERT="${combined}" \
		NODE_EXTRA_CA_CERTS="${CX_CA_BUNDLE}" CX_CA_COMBINED="${combined}"
	return 0
}

set_output() { [[ -n "${GITHUB_OUTPUT:-}" ]] && printf '%s=%s\n' "$1" "$2" >> "${GITHUB_OUTPUT}"; return 0; }
mask() { [[ -n "${1:-}" ]] && echo "::add-mask::$1"; return 0; }

# Estado compartido entre pasos (detect.sh lo escribe, el resto lo lee).
state_set() {
	local k="$1" v="$2"
	touch "${CX_STATE}"
	grep -v "^${k}=" "${CX_STATE}" > "${CX_STATE}.tmp" || true
	printf '%s=%q\n' "${k}" "${v}" >> "${CX_STATE}.tmp"
	mv "${CX_STATE}.tmp" "${CX_STATE}"
}
state_load() {
	# shellcheck source=/dev/null
	[[ -f "${CX_STATE}" ]] && source "${CX_STATE}"
	# shellcheck source=/dev/null
	[[ -f "${CX_ENV_FILE}" ]] && source "${CX_ENV_FILE}"
	return 0
}

# Ejecuta con timeout si existe; $1 = duracion (p.ej. 20m)
run_timeout() { local t="$1"; shift; if command -v timeout >/dev/null 2>&1; then timeout --foreground "${t}" "$@"; else "$@"; fi; }

# curl con reintentos, TLS corporativo y credenciales de Artifactory solo para su host.
curl_get() {  # curl_get <url> <dest>
	local url="$1" dest="$2"
	local -a args=(-fsSL --retry 3 --retry-delay 3 --connect-timeout 20 --max-time 600 -o "${dest}")
	[[ -n "${CX_CA_BUNDLE:-}" && -f "${CX_CA_BUNDLE}" ]] && args+=(--cacert "${CX_CA_BUNDLE}")
	if [[ -n "${ARTIFACTORY_URL:-}" && "${url}" == "${ARTIFACTORY_URL%/}"/* ]]; then
		if [[ -n "${ARTIFACTORY_TOKEN:-}" ]]; then
			args+=(-H "Authorization: Bearer ${ARTIFACTORY_TOKEN}")
		elif [[ -n "${ARTIFACTORY_USER:-}" && -n "${ARTIFACTORY_PASSWORD:-}" ]]; then
			args+=(-u "${ARTIFACTORY_USER}:${ARTIFACTORY_PASSWORD}")
		fi
	fi
	curl "${args[@]}" "${url}"
}

host_of() { printf '%s' "$1" | sed -E 's#^[a-zA-Z][a-zA-Z0-9+.-]*://([^/@]*@)?([^/:]+).*#\2#'; }

# sha256 portable
sha256_of() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$@"; else shasum -a 256 "$@"; fi; }

# Ruta relativa a SOURCE_DIR para logs
rel() { local p="${1%/}"; [[ "${p}" == "${SOURCE_DIR%/}" ]] && echo "." || echo "${p#"${SOURCE_DIR%/}"/}"; }
