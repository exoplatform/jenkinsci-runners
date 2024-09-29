#!/bin/bash
. /etc/profile
. /etc/os-release
echo
echo "  ------------------------------------------- BUILD ENVIRONMENT -------------------------------------------"
echo "  * OS Type: ${NAME} (machine)"
if [ ! -z "${VERSION_ID:-}" ]; then
    echo "  * OS Version: ${VERSION_ID}"
elif [ ! -z "${VERSION:-}" ]; then
    echo "  * OS Version: ${VERSION}"
fi
if [ ! -z "${VERSION_CODENAME:-}" ]; then
    echo "  * OS Version Code Name: ${VERSION_CODENAME}"
fi
echo "  * Host Kernel Version: $(uname -r)"
if [ ! -z "${JAVA_HOME:-}" ]; then
    echo "  * JAVA_HOME: ${JAVA_HOME}"
fi
if hash docker &>/dev/null; then
    echo "  * Docker Build: $(docker --version 2>&1 | tail -1)"
    echo "  * Docker Bin: $(which docker)"
    echo "  *$(docker info | grep -i 'Docker Root Dir')"
    echo "  * Docker Available$(docker info | grep -i 'CPUs')"
fi
if hash java &>/dev/null; then
    echo "  * JDK Build: $(java -version 2>&1 | tail -1)"
    echo "  * JAVA Bin: $(which java)"
fi
if hash mvn &>/dev/null; then
    echo "  * Maven Version: $(mvn --version | head -1 | grep -oP '[0-9]+\.[0-9]+\.[0-9]+')"
    echo "  * Maven Bin: $(which mvn)"
fi
if hash gradle &>/dev/null; then
    echo "  * Gradle Version: $(gradle --version | grep Gradle | grep -oP '[0-9]+\.[0-9]+\.[0-9]+')"
    echo "  * Gradle Bin: $(which gradle)"
fi
echo "  ---------------------------------------------------------------------------------------------------------"
echo