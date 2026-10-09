#!/usr/bin/env bash
# =====================================================================================================
# install-tools.sh — cx CLI, ScaResolver y SOLO los helpers que falten en el runner
# =====================================================================================================
# Uso: install-tools.sh cx            -> instala/valida el cx CLI (siempre necesario)
#      install-tools.sh resolver      -> ScaResolver + helpers de los ecosistemas detectados
# Todo se instala en CX_TOOLS (persistido con actions/cache por version): en la 2da ejecucion no se
# descarga nada. Los JDK/Node/Python/.NET/Go los pone action.yml con setup-* SOLO si faltan.
# Las URLs aceptan {version} y {arch}: apuntarlas a un repo "generic remote" de Artifactory en on-prem.
# =====================================================================================================
set -Eeuo pipefail
CX_STEP=tools
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
state_load
load_secret_env
setup_ca

WHAT="${1:-cx}"
ARCH="$(uname -m)"; case "${ARCH}" in x86_64|amd64) CX_ARCH=x64 ;; aarch64|arm64) CX_ARCH=arm64 ;; *) CX_ARCH="${ARCH}" ;; esac
CX_CACHE="${CX_CACHE:-${HOME}/.cache/cx-one}"
BIN="${CX_TOOLS}/bin"; mkdir -p "${BIN}"; add_path "${BIN}"

expand() { local s="$1"; s="${s//\{version\}/$2}"; s="${s//\{arch\}/${CX_ARCH}}"; echo "${s}"; }

fetch_tar() {  # fetch_tar <url> <dest_dir>
	local url="$1" dest="$2" tmp
	tmp="$(mktemp -d)"; mkdir -p "${dest}"
	log "Descargando ${url}"
	curl_get "${url}" "${tmp}/pkg" || die "No se pudo descargar ${url}"
	# checksum publicado junto al artefacto (best effort: ScaResolver lo publica como .sha256sum)
	if curl_get "${url}.sha256sum" "${tmp}/pkg.sha" 2>/dev/null; then
		local expected; expected="$(awk '{print $1}' "${tmp}/pkg.sha" | head -n1)"
		[[ "$(sha256_of "${tmp}/pkg" | cut -d' ' -f1)" == "${expected}" ]] || die "Checksum SHA-256 invalido para ${url}"
		log "Checksum SHA-256 verificado"
	fi
	case "${url}" in
		*.zip) unzip -q -o "${tmp}/pkg" -d "${dest}" ;;
		*)     tar -xzf "${tmp}/pkg" -C "${dest}" ;;
	esac
	rm -rf "${tmp}"
}

install_cx() {
	if [[ "${CX_CLI_VERSION:-}" == system ]]; then   # imagen de runner con cx preinstalado (runner-image/)
		local sys; sys="$(command -v cx)" || die "cx-cli-version=system pero 'cx' no esta en el PATH"
		set_env CX_BIN "${sys}"; state_set CX_BIN "${sys}"; log "cx del sistema: ${sys}"; return 0
	fi
	local v="${CX_CLI_VERSION:-2.3.66}" dir="${CX_TOOLS}/cx/${CX_CLI_VERSION:-2.3.66}"
	local url; url="$(expand "${CX_CLI_URL:-https://github.com/Checkmarx/ast-cli/releases/download/{version}/ast-cli_{version}_linux_{arch}.tar.gz}" "${v}")"
	if [[ ! -x "${dir}/cx" ]]; then fetch_tar "${url}" "${dir}"; else log "cx ${v} en cache"; fi
	chmod +x "${dir}/cx"
	set_env CX_BIN "${dir}/cx"; state_set CX_BIN "${dir}/cx"
	log "cx: $("${dir}/cx" version 2>/dev/null | head -n1 || echo "${v}")"
}

install_resolver() {
	if [[ "${CX_SCA_RESOLVER_VERSION:-}" == system ]]; then
		local sys; sys="$(command -v ScaResolver)" || die "sca-resolver-version=system pero 'ScaResolver' no esta en el PATH"
		sys="$(readlink -f "${sys}")"   # Configuration.yml vive junto al binario real
		set_env SCA_RESOLVER_BIN "${sys}"; state_set SCA_RESOLVER_BIN "${sys}"; log "ScaResolver del sistema: ${sys}"; return 0
	fi
	local v="${CX_SCA_RESOLVER_VERSION:-latest}" dir="${CX_TOOLS}/sca-resolver/${CX_SCA_RESOLVER_VERSION:-latest}"
	[[ "${CX_ARCH}" == x64 ]] || warn "ScaResolver solo se publica para linux x64; arquitectura actual ${CX_ARCH}."
	local url; url="$(expand "${CX_SCA_RESOLVER_URL:-https://sca-downloads.s3.amazonaws.com/cli/{version}/ScaResolver-linux64.tar.gz}" "${v}")"
	if [[ ! -x "${dir}/ScaResolver" ]]; then fetch_tar "${url}" "${dir}"; else log "ScaResolver ${v} en cache"; fi
	chmod +x "${dir}/ScaResolver"
	[[ -f "${dir}/Configuration.yml" ]] || warn "Configuration.yml no esta junto a ScaResolver (es obligatorio desde 2.0)."
	set_env SCA_RESOLVER_BIN "${dir}/ScaResolver"; state_set SCA_RESOLVER_BIN "${dir}/ScaResolver"
	log "ScaResolver: $("${dir}/ScaResolver" --version 2>/dev/null | tail -n1 || echo "${v}")"
}

# ---------------------------------------------------------------- helpers por ecosistema
install_maven() {
	command -v mvn >/dev/null 2>&1 && return 0
	local v="${CX_MAVEN_VERSION:-3.9.9}" dir="${CX_TOOLS}/maven"
	local url; url="$(expand "${CX_MAVEN_DIST_URL:-https://archive.apache.org/dist/maven/maven-3/{version}/binaries/apache-maven-{version}-bin.tar.gz}" "${v}")"
	[[ -x "${dir}/apache-maven-${v}/bin/mvn" ]] || fetch_tar "${url}" "${dir}"
	add_path "${dir}/apache-maven-${v}/bin"
	log "Maven ${v} listo"
}

install_gradle() {
	command -v gradle >/dev/null 2>&1 && return 0
	local v="${CX_GRADLE_VERSION:-}" dir="${CX_TOOLS}/gradle" props
	if [[ -z "${v}" ]]; then
		props="$(grep -m1 'gradle-wrapper.properties' "${CX_WORK}/manifests.list" || true)"
		[[ -n "${props}" ]] && v="$(grep -Eo 'gradle-[0-9]+(\.[0-9]+)*-(bin|all)\.zip' "${props}" | sed -E 's/^gradle-//; s/-(bin|all)\.zip$//' | head -n1)"
	fi
	v="${v:-8.10.2}"
	local url; url="$(expand "${CX_GRADLE_DIST_URL:-https://services.gradle.org/distributions/gradle-{version}-bin.zip}" "${v}")"
	[[ -x "${dir}/gradle-${v}/bin/gradle" ]] || fetch_tar "${url}" "${dir}"
	add_path "${dir}/gradle-${v}/bin"
	log "Gradle ${v} listo (el proyecto no versiona gradlew)"
}

python_user_pkg() {  # instala modulos python en PYTHONUSERBASE (cacheado), sin tocar el python del sistema
	local mod="$1" pkg="${2:-$1}"
	set_env PYTHONUSERBASE "${CX_CACHE}/pyuser"
	add_path "${CX_CACHE}/pyuser/bin"
	python3 -m "${mod}" --version >/dev/null 2>&1 && return 0
	log "Instalando ${pkg} (prerequisito de ScaResolver)"
	PIP_BREAK_SYSTEM_PACKAGES=1 python3 -m pip install --user --quiet --no-warn-script-location "${pkg}" \
		|| die "No se pudo instalar ${pkg} (revisa pypi-repo / .netrc)"
}

install_yarn() {
	command -v yarn >/dev/null 2>&1 && return 0
	if command -v corepack >/dev/null 2>&1; then
		# --install-directory evita el EACCES de "corepack enable" sobre /usr/bin en runners no-root
		corepack enable --install-directory "${BIN}" yarn && command -v yarn >/dev/null 2>&1 && { log "yarn via corepack"; return 0; }
	fi
	npm install -g --prefix "${CX_TOOLS}/npm-global" --no-audit --no-fund yarn >/dev/null
	add_path "${CX_TOOLS}/npm-global/bin"
}

case "${WHAT}" in
	cx) install_cx ;;
	resolver)
		install_resolver
		[[ "${NEED_MAVEN:-false}" == true ]] && install_maven
		[[ "${NEED_GRADLE:-false}" == true ]] && install_gradle
		[[ "${NEED_YARN:-false}" == true ]] && install_yarn
		if [[ "${NEED_PYTHON:-false}" == true ]]; then
			python_user_pkg virtualenv            # ScaResolver: "python -m virtualenv" por manifiesto
			[[ "${NEED_POETRY:-false}" == true ]] && { command -v poetry >/dev/null 2>&1 || python_user_pkg poetry; }
			if [[ "${NEED_UV:-false}" == true || "${CX_PYTHON_PACKAGE_MANAGER:-pip}" == uv ]]; then command -v uv >/dev/null 2>&1 || python_user_pkg uv; fi
		fi
		for t in composer bundler; do
			v="NEED_${t^^}"
			if [[ "${!v:-false}" == true ]] && ! command -v "${t/bundler/bundle}" >/dev/null 2>&1; then
				warn "${t} no esta en el runner: ScaResolver no podra resolver esos manifiestos (incluirlo en la imagen del runner)."
			fi
		done
		;;
	*) die "uso: install-tools.sh cx|resolver" ;;
esac
