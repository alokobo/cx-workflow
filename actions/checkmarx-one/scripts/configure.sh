#!/usr/bin/env bash
# =====================================================================================================
# configure.sh — apunta TODOS los gestores de paquetes a Artifactory (on-premise) SIN instalar nada.
# =====================================================================================================
# Principio: Checkmarx One es analisis estatico. No se compila, no se hace npm ci / pip install / gradle
# build. Solo se deja la configuracion para que ScaResolver (que invoca al gestor en modo "solo metadata"
# cuando puede) llegue a Artifactory con credenciales.
#
# Mecanismo oficial de ScaResolver: <raiz>/.cxsca.configurations/{settings.xml,.npmrc,nuget.config}
# se aplica a TODOS los modulos y sobreescribe la config local de cada uno.
#   -> Esos archivos se suben a Checkmarx junto con los manifiestos ("Files Used for Manifest Resolution"),
#      por eso NUNCA llevan secretos: referencian variables de entorno (${env.X} en Maven, ${X} en npm,
#      %X% en NuGet) que solo existen en el proceso de ScaResolver.
#   -> resolve.sh elimina la carpeta antes del zip de cx scan (y cleanup.sh como red de seguridad).
# Unico secreto en disco: .netrc (pip/uv/poetry/go/curl) en $RUNNER_TEMP, chmod 600, borrado en cleanup.
#
# Entradas (env): ARTIFACTORY_URL (https://host/artifactory), ARTIFACTORY_USER, ARTIFACTORY_PASSWORD
#   (password, API key o access token), ARTIFACTORY_TOKEN (opcional, bearer para npm/curl),
#   CX_REPO_{NPM,MAVEN,GRADLE_PLUGINS,PYPI,NUGET,GO,COMPOSER,GEMS} (nombre del repo VIRTUAL en Artifactory),
#   CX_LEGACY_HOSTS (csv "hostviejo=hostnuevo"), CX_CA_BUNDLE (PEM corporativo), CX_JAVA_TRUSTSTORE,
#   CX_OVERRIDE_REPO_CONFIG (true: reemplaza .cxsca.configurations del repo si existiera)
# =====================================================================================================
set -Eeuo pipefail
CX_STEP=configure
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
state_load

SRC="${SOURCE_DIR:?detect.sh debe ejecutarse antes}"
ECOS=",${ECOSYSTEMS:-},"
has_eco() { local e; for e in "$@"; do [[ "${ECOS}" == *",${e},"* ]] && return 0; done; return 1; }

ART="${ARTIFACTORY_URL:-}"; ART="${ART%/}"
USER_="${ARTIFACTORY_USER:-}"; PASS_="${ARTIFACTORY_PASSWORD:-${ARTIFACTORY_TOKEN:-}}"
mask "${PASS_}"; mask "${ARTIFACTORY_TOKEN:-}"
set_env ARTIFACTORY_URL "${ART}"     # no secreto; lo usan curl_get y load_secret_env en los siguientes pasos

# Cache estable entre ejecuciones (actions/cache la persiste; en runners persistentes se reutiliza sola)
CX_CACHE="${CX_CACHE:-${HOME}/.cache/cx-one}"
mkdir -p "${CX_CACHE}"
set_env CX_CACHE "${CX_CACHE}"

# Credenciales: NO se exportan aqui. load_secret_env (lib.sh) las deriva en memoria dentro de los procesos
# que las usan (ScaResolver y gestores hijos); los archivos generados solo referencian sus nombres.

url_for() {  # url_for <tipo> <repo>
	local repo="$2"; [[ -n "${ART}" && -n "${repo}" ]] || return 0
	case "$1" in
		npm)      echo "${ART}/api/npm/${repo}/" ;;
		maven)    echo "${ART}/${repo}" ;;
		pypi)     echo "${ART}/api/pypi/${repo}/simple" ;;
		nuget)    echo "${ART}/api/nuget/v3/${repo}/index.json" ;;
		go)       echo "${ART}/api/go/${repo}" ;;
		composer) echo "${ART}/api/composer/${repo}" ;;
		gems)     echo "${ART}/api/gems/${repo}/" ;;
	esac
}
NPM_URL="${CX_NPM_URL:-$(url_for npm "${CX_REPO_NPM:-}")}"
MAVEN_URL="${CX_MAVEN_URL:-$(url_for maven "${CX_REPO_MAVEN:-}")}"
GRADLE_PLUGINS_URL="${CX_GRADLE_PLUGINS_URL:-$(url_for maven "${CX_REPO_GRADLE_PLUGINS:-}")}"
PYPI_URL="${CX_PYPI_URL:-$(url_for pypi "${CX_REPO_PYPI:-}")}"
NUGET_URL="${CX_NUGET_URL:-$(url_for nuget "${CX_REPO_NUGET:-}")}"
GO_URL="${CX_GO_URL:-$(url_for go "${CX_REPO_GO:-}")}"
COMPOSER_URL="${CX_COMPOSER_URL:-$(url_for composer "${CX_REPO_COMPOSER:-}")}"
GEMS_URL="${CX_GEMS_URL:-$(url_for gems "${CX_REPO_GEMS:-}")}"
ART_HOST=""; [[ -n "${ART}" ]] && ART_HOST="$(host_of "${ART}")"

CFG_DIR="${SRC}/.cxsca.configurations"
if [[ -d "${CFG_DIR}" && ! -f "${CFG_DIR}/.cx-one-generated" ]] && ! is_true "${CX_OVERRIDE_REPO_CONFIG:-false}"; then
	log "El repositorio ya trae .cxsca.configurations/: se respeta (override-repo-config=false)."
	GENERATE_CFG=false
else
	mkdir -p "${CFG_DIR}"; touch "${CFG_DIR}/.cx-one-generated"; GENERATE_CFG=true
	state_set CFG_DIR_GENERATED "${CFG_DIR}"
fi

# Comunes ------------------------------------------------------------------------------------------
setup_ca     # bundle combinado; cada script lo vuelve a aplicar (no depende de env.sh)

# .netrc: unico archivo con secreto, fuera del workspace (pip, uv, poetry, go, curl y ScaResolver --netrc-path)
if [[ -n "${ART_HOST}" && -n "${USER_}" && -n "${PASS_}" ]]; then
	NETRC="${CX_WORK}/netrc"
	( umask 077; printf 'machine %s\nlogin %s\npassword %s\n' "${ART_HOST}" "${USER_}" "${PASS_}" > "${NETRC}" )
	set_env NETRC "${NETRC}"
	state_set NETRC_FILE "${NETRC}"
fi

SUMMARY=()

# Maven -------------------------------------------------------------------------------------------
if has_eco maven && [[ -n "${MAVEN_URL}" && "${GENERATE_CFG}" == true ]]; then
	cat > "${CFG_DIR}/settings.xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!-- Generado por cx-one (solo resolucion SCA). Sin secretos: Maven expande \${env.*} en tiempo de ejecucion. -->
<settings xmlns="http://maven.apache.org/SETTINGS/1.2.0">
  <interactiveMode>false</interactiveMode>
  <servers>
    <server>
      <id>cx-artifactory</id>
      <username>\${env.CX_ART_USER}</username>
      <password>\${env.CX_ART_PASS}</password>
    </server>
  </servers>
  <mirrors>
    <mirror>
      <id>cx-artifactory</id>
      <name>Artifactory (virtual)</name>
      <url>${MAVEN_URL}</url>
      <mirrorOf>${CX_MAVEN_MIRROR_OF:-*}</mirrorOf>
    </mirror>
  </mirrors>
</settings>
EOF
	# Batch + sin barra de progreso; -T para paralelizar la descarga de POMs en multi-modulo
	set_env MAVEN_ARGS "--batch-mode --no-transfer-progress"
	SUMMARY+=("maven → ${MAVEN_URL}")
fi
[[ -n "${CX_JAVA_TRUSTSTORE:-}" ]] && set_env JAVA_TOOL_OPTIONS "-Djavax.net.ssl.trustStore=${CX_JAVA_TRUSTSTORE} ${JAVA_TOOL_OPTIONS:-}"

# Gradle ------------------------------------------------------------------------------------------
if has_eco gradle; then
	GUH="${CX_CACHE}/gradle"
	mkdir -p "${GUH}/init.d"
	set_env GRADLE_USER_HOME "${GUH}"
	cat > "${GUH}/gradle.properties" <<'EOF'
org.gradle.daemon=false
org.gradle.parallel=true
org.gradle.caching=false
org.gradle.console=plain
org.gradle.vfs.watch=false
org.gradle.jvmargs=-Xmx2g -XX:MaxMetaspaceSize=512m -Dfile.encoding=UTF-8
EOF
	# (credenciales del wrapper: -Dgradle.wrapperUser/Password se agregan en memoria en load_secret_env)
	set_env GRADLE_OPTS "-Dorg.gradle.daemon=false"

	# Init script: (1) host legado -> host actual, (2) repos publicos -> Artifactory (si hay MAVEN_URL),
	# (3) credenciales para todo repo en el host de Artifactory. Lee secretos de System.getenv en runtime.
	legacy_map=""
	IFS=',' read -r -a pairs <<< "${CX_LEGACY_HOSTS:-}"
	for p in "${pairs[@]}"; do p="${p//[[:space:]]/}"; [[ "${p}" == *=* ]] && legacy_map+="'${p%%=*}': '${p#*=}', "; done
	legacy_map="${legacy_map%, }"; [[ -z "${legacy_map}" ]] && legacy_map=":"
	cat > "${GUH}/init.d/10-cx-one-repos.gradle" <<EOF
// Generado por cx-one: SOLO afecta la resolucion en el runner; no modifica el proyecto.
import org.gradle.api.artifacts.repositories.MavenArtifactRepository
import org.gradle.api.artifacts.repositories.UrlArtifactRepository

final Map<String, String> LEGACY = [${legacy_map}]
final String ART_HOST = '${ART_HOST}'
final String MIRROR = '${MAVEN_URL}'
final String PLUGINS = '${GRADLE_PLUGINS_URL:-${MAVEN_URL}}'
final Set<String> PUBLIC = ['repo.maven.apache.org', 'repo1.maven.org', 'dl.google.com', 'maven.google.com',
                            'plugins.gradle.org', 'jcenter.bintray.com', 'jitpack.io'] as Set
final String U = System.getenv('CX_ART_USER') ?: ''
final String P = System.getenv('CX_ART_PASS') ?: ''

final Set<String> PLUGIN_HOSTS = ['plugins.gradle.org'] as Set
def fix = { repo, boolean pluginCtx ->
    if (!(repo instanceof UrlArtifactRepository) || repo.url == null) return
    URI u = repo.url
    String host = u.host ?: ''
    if (LEGACY.containsKey(host)) {
        u = new URI(u.scheme, u.userInfo, LEGACY[host], u.port, u.path, u.query, u.fragment); repo.url = u; host = u.host
    }
    // plugins.gradle.org -> repo de plugins; Central/Google/JitPack -> virtual Maven (aunque esten en pluginManagement)
    if (MIRROR && PUBLIC.contains(host)) { repo.url = (PLUGIN_HOSTS.contains(host) ? PLUGINS : MIRROR); host = new URI(repo.url.toString()).host }
    if (repo.url.scheme == 'http') { repo.allowInsecureProtocol = true }
    if (ART_HOST && host == ART_HOST && U && P && repo instanceof MavenArtifactRepository) {
        repo.credentials { username = U; password = P }
    }
}
def wire = { handler, boolean plugin -> handler.configureEach { fix(it, plugin) } }

// beforeSettings: aplica tambien a los plugins declarados en settings.gradle (foojay, com.facebook.react.settings...)
// que se resuelven mientras se evalua settings; configureEach cubre repos agregados despues.
beforeSettings { s ->
    wire(s.pluginManagement.repositories, true)
    wire(s.buildscript.repositories, true)
    try { wire(s.dependencyResolutionManagement.repositories, false) } catch (Throwable ignored) { }
}
allprojects { p ->
    wire(p.buildscript.repositories, true)
    wire(p.repositories, false)
}
EOF
	SUMMARY+=("gradle → ${MAVEN_URL:-repos del proyecto} (init script, GRADLE_USER_HOME=${GUH})")
fi

# JavaScript (npm / yarn / pnpm) ------------------------------------------------------------------
if has_eco npm yarn pnpm bower && [[ -n "${NPM_URL}" ]]; then
	reg_path="//${NPM_URL#*://}"
	{
		echo "registry=${NPM_URL}"
		if [[ -n "${ARTIFACTORY_TOKEN:-}" ]]; then echo "${reg_path}:_authToken=\${ARTIFACTORY_TOKEN}"
		elif [[ -n "${USER_}" && -n "${PASS_}" ]]; then echo "${reg_path}:_auth=\${CX_NPM_AUTH}"; fi
		echo "ignore-scripts=true"          # supply-chain: nunca ejecutar lifecycle scripts durante la resolucion
		echo "audit=false"
		echo "fund=false"
		echo "update-notifier=false"
		echo "fetch-retries=3"
		echo "prefer-offline=true"          # reutiliza la cache restaurada antes de ir a la red
		[[ -n "${CX_CA_COMBINED:-}" ]] && echo "cafile=${CX_CA_COMBINED}"
		# Scopes privados del .npmrc del repo (@empresa:registry=...) -> al mismo registry virtual
		if [[ -f "${SRC}/.npmrc" ]]; then
			grep -oE '^@[A-Za-z0-9._-]+:registry' "${SRC}/.npmrc" | sort -u | sed "s|\$|=${NPM_URL}|" || true
		fi
	} > "${CX_WORK}/npmrc"
	set_env NPM_CONFIG_USERCONFIG "${CX_WORK}/npmrc"      # npm, pnpm, yarn v1 y corepack
	set_env npm_config_cache "${CX_CACHE}/npm"
	set_env YARN_CACHE_FOLDER "${CX_CACHE}/yarn"
	set_env YARN_REGISTRY "${NPM_URL}"                        # yarn v1 (ignora NPM_CONFIG_USERCONFIG)
	set_env YARN_NPM_REGISTRY_SERVER "${NPM_URL%/}"          # yarn berry
	set_env YARN_ENABLE_SCRIPTS "false"
	set_env YARN_ENABLE_TELEMETRY "0"
	set_env COREPACK_NPM_REGISTRY "${NPM_URL%/}"
	set_env COREPACK_ENABLE_DOWNLOAD_PROMPT "0"
	[[ "${GENERATE_CFG}" == true ]] && cp "${CX_WORK}/npmrc" "${CFG_DIR}/.npmrc"
	SUMMARY+=("npm/yarn/pnpm → ${NPM_URL}")
fi

# Python (pip / uv / poetry) ----------------------------------------------------------------------
if has_eco pip uv poetry pipenv; then
	set_env PIP_CACHE_DIR "${CX_CACHE}/pip"
	set_env PIP_DISABLE_PIP_VERSION_CHECK "1"
	set_env PIP_NO_INPUT "1"
	set_env PIP_PREFER_BINARY "1"            # evita compilar sdists dentro del virtualenv de ScaResolver
	set_env PIP_DEFAULT_TIMEOUT "60"
	set_env UV_CACHE_DIR "${CX_CACHE}/uv"
	[[ -n "${CX_CA_BUNDLE:-}" ]] && set_env UV_NATIVE_TLS "true"
	if [[ -n "${PYPI_URL}" ]]; then
		set_env PIP_INDEX_URL "${PYPI_URL}"        # credenciales via .netrc (pip lo soporta nativamente)
		set_env UV_DEFAULT_INDEX "${PYPI_URL}"
		set_env UV_INDEX_URL "${PYPI_URL}"         # uv < 0.4.23
		SUMMARY+=("pip/uv → ${PYPI_URL} (poetry: usa las [[tool.poetry.source]] del pyproject + .netrc)")
	fi
fi

# .NET --------------------------------------------------------------------------------------------
if has_eco nuget; then
	set_env NUGET_PACKAGES "${HOME}/.nuget/packages"
	set_env DOTNET_CLI_TELEMETRY_OPTOUT "1"; set_env DOTNET_NOLOGO "1"; set_env DOTNET_SKIP_FIRST_TIME_EXPERIENCE "1"
	if [[ -n "${NUGET_URL}" && "${GENERATE_CFG}" == true ]]; then
		cat > "${CFG_DIR}/nuget.config" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<!-- Generado por cx-one. Sin secretos: NuGet expande %VAR% al leer la configuracion. -->
<configuration>
  <packageSources>
    <clear />
    <add key="cxartifactory" value="${NUGET_URL}" protocolVersion="3" />
  </packageSources>
  <packageSourceCredentials>
    <cxartifactory>
      <add key="Username" value="%CX_ART_USER%" />
      <add key="ClearTextPassword" value="%CX_ART_PASS%" />
    </cxartifactory>
  </packageSourceCredentials>
</configuration>
EOF
		# + NuGetPackageSourceCredentials_cxartifactory (env, sin archivo) en load_secret_env
		SUMMARY+=("nuget → ${NUGET_URL}")
	fi
fi

# Go / PHP / Ruby ---------------------------------------------------------------------------------
if has_eco go; then
	set_env GOMODCACHE "${CX_CACHE}/go/mod"; set_env GOFLAGS "-mod=mod"; set_env GOTOOLCHAIN "local"
	if [[ -n "${GO_URL}" ]]; then
		set_env GOPROXY "${GO_URL}"; set_env GOSUMDB "${CX_GOSUMDB:-off}"   # go.sum del repo sigue validando lo ya fijado
		SUMMARY+=("go → ${GO_URL}")
	fi
fi
if has_eco composer; then
	set_env COMPOSER_CACHE_DIR "${CX_CACHE}/composer"; set_env COMPOSER_NO_INTERACTION "1"
	# COMPOSER_AUTH (http-basic) se deriva en memoria en load_secret_env
	[[ -n "${COMPOSER_URL}" ]] && SUMMARY+=("composer → ${COMPOSER_URL} (declarar el repo en composer.json)")
fi
# rubygems: BUNDLE_<HOST>=user:pass se deriva en memoria en load_secret_env
has_eco rubygems && [[ -n "${GEMS_URL}" ]] && SUMMARY+=("rubygems → ${GEMS_URL} (Gemfile source)")

if [[ -z "${ART}" ]]; then
	warn "artifactory-url no configurado: los gestores usaran los registries publicos (requiere salida a Internet)."
fi
log "Configuracion aplicada:"; for s in "${SUMMARY[@]:-}"; do [[ -n "${s}" ]] && log "  - ${s}"; done
if [[ "${GENERATE_CFG}" == true ]]; then
	gen=(); for f in "${CFG_DIR}"/* "${CFG_DIR}"/.npmrc; do [[ -f "${f}" ]] && gen+=("$(basename "${f}")"); done
	log ".cxsca.configurations generado (sin secretos): ${gen[*]:-<vacio>}"
fi
exit 0
