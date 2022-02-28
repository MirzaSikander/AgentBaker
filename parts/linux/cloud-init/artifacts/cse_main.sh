#!/bin/bash
IS_UU_ENABLED={{IsUnattendedUpgradeEnabled}}
apply_unattended_upgrade_config (){
    local uu_file_path="/etc/apt/apt.conf.d/99periodic"
    [[ -e $uu_file_path ]] && rm -f $uu_file_path
    if [[ ${IS_UU_ENABLED} == "false" ]]; then
        cat << 'EOF' >> ${uu_file_path}
APT::Periodic::Update-Package-Lists "0";
APT::Periodic::Download-Upgradeable-Packages "0";
APT::Periodic::AutocleanInterval "0";
APT::Periodic::Unattended-Upgrade "0";
EOF
        echo "Unattended upgrade disabled"
    fi
}

ERR_FILE_WATCH_TIMEOUT=6 {{/* Timeout waiting for a file */}}
set -x
if [ -f /opt/azure/containers/provision.complete ]; then
    apply_unattended_upgrade_config
    echo "Already ran to success exiting..."
    exit 0
fi

UBUNTU_RELEASE=$(lsb_release -r -s)
if [[ ${UBUNTU_RELEASE} == "16.04" ]]; then
    sudo apt-get -y autoremove chrony
    echo $?
    sudo systemctl restart systemd-timesyncd
fi

echo $(date),$(hostname), startcustomscript>>/opt/m

for i in $(seq 1 3600); do
    if [ -s {{GetCSEHelpersScriptFilepath}} ]; then
        grep -Fq '#HELPERSEOF' {{GetCSEHelpersScriptFilepath}} && break
    fi
    if [ $i -eq 3600 ]; then
        exit $ERR_FILE_WATCH_TIMEOUT
    else
        sleep 1
    fi
done
sed -i "/#HELPERSEOF/d" {{GetCSEHelpersScriptFilepath}}
source {{GetCSEHelpersScriptFilepath}}

wait_for_file 3600 1 {{GetCSEHelpersScriptDistroFilepath}} || exit $ERR_FILE_WATCH_TIMEOUT
source {{GetCSEHelpersScriptDistroFilepath}}

wait_for_file 3600 1 {{GetCSEInstallScriptFilepath}} || exit $ERR_FILE_WATCH_TIMEOUT
source {{GetCSEInstallScriptFilepath}}

wait_for_file 3600 1 {{GetCSEInstallScriptDistroFilepath}} || exit $ERR_FILE_WATCH_TIMEOUT
source {{GetCSEInstallScriptDistroFilepath}}

wait_for_file 3600 1 {{GetCSEConfigScriptFilepath}} || exit $ERR_FILE_WATCH_TIMEOUT
source {{GetCSEConfigScriptFilepath}}

{{- if not NeedsContainerd}}
cleanUpContainerd
{{- end}}

if [[ "${GPU_NODE}" != "true" ]]; then
    cleanUpGPUDrivers
fi

{{- if ShouldConfigureHTTPProxyCA}}
configureHTTPProxyCA
{{- end}}

disable1804SystemdResolved

if [ -f /var/run/reboot-required ]; then
    REBOOTREQUIRED=true
else
    REBOOTREQUIRED=false
fi

configureAdminUser

{{- if NeedsContainerd}}
# If crictl gets installed then use it as the cri cli instead of ctr
# crictl is not a critical component so continue with boostrapping if the install fails
# CLI_TOOL is by default set to "ctr"
installCrictl && CLI_TOOL="crictl"
{{- end}}

VHD_LOGS_FILEPATH=/opt/azure/vhd-install.complete
if [ -f $VHD_LOGS_FILEPATH ]; then
    echo "detected golden image pre-install"
    cleanUpContainerImages
    FULL_INSTALL_REQUIRED=false
else
    if [[ "${IS_VHD}" = true ]]; then
        echo "Using VHD distro but file $VHD_LOGS_FILEPATH not found"
        exit $ERR_VHD_FILE_NOT_FOUND
    fi
    FULL_INSTALL_REQUIRED=true
fi

if [[ $OS == $UBUNTU_OS_NAME ]] && [ "$FULL_INSTALL_REQUIRED" = "true" ]; then
    installDeps
else
    echo "Golden image; skipping dependencies installation"
fi

installContainerRuntime
{{- if and NeedsContainerd TeleportEnabled}}
installTeleportdPlugin
{{- end}}

setupCNIDirs

installNetworkPlugin

{{- if IsKrustlet }}
    downloadKrustlet
{{- end }}

{{- if IsNSeriesSKU}}
echo $(date),$(hostname), "Start configuring GPU drivers"
if [[ "${GPU_NODE}" = true ]]; then
    if $FULL_INSTALL_REQUIRED; then
        installGPUDrivers
    fi
    ensureGPUDrivers
    if [[ "${ENABLE_GPU_DEVICE_PLUGIN_IF_NEEDED}" = true ]]; then
        if [[ "${MIG_NODE}" == "true" ]] && [[ -f "/etc/systemd/system/nvidia-device-plugin.service" ]]; then
            wait_for_file 3600 1 /etc/systemd/system/nvidia-device-plugin.service.d/10-mig_strategy.conf || exit $ERR_FILE_WATCH_TIMEOUT
        fi
        systemctlEnableAndStart nvidia-device-plugin || exit $ERR_GPU_DEVICE_PLUGIN_START_FAIL
    else
        systemctlDisableAndStop nvidia-device-plugin
    fi
fi
# If it is a MIG Node, enable mig-partition systemd service to create MIG instances
if [[ "${MIG_NODE}" == "true" ]]; then
    REBOOTREQUIRED=true
    STATUS=`systemctl is-active nvidia-fabricmanager`
    if [ ${STATUS} = 'active' ]; then
        echo "Fabric Manager service is running, no need to install."
    else
        if [ -d "/opt/azure/fabricmanager-${GPU_DV}" ] && [ -f "/opt/azure/fabricmanager-${GPU_DV}/fm_run_package_installer.sh" ]; then
            pushd /opt/azure/fabricmanager-${GPU_DV}
            /opt/azure/fabricmanager-${GPU_DV}/fm_run_package_installer.sh
            systemctlEnableAndStart nvidia-fabricmanager
            popd
        else
            echo "Need to install nvidia-fabricmanager, but failed to find on disk. Will not pull (breaks AKS egress contract)."
        fi
    fi
    ensureMigPartition
fi

echo $(date),$(hostname), "End configuring GPU drivers"
{{end}}

{{- if and IsDockerContainerRuntime HasPrivateAzureRegistryServer}}
set +x
docker login -u $SERVICE_PRINCIPAL_CLIENT_ID -p $SERVICE_PRINCIPAL_CLIENT_SECRET {{GetPrivateAzureRegistryServer}}
set -x
{{end}}

installKubeletKubectlAndKubeProxy

ensureRPC

createKubeManifestDir

{{- if HasDCSeriesSKU}}
if [[ ${SGX_NODE} == true && ! -e "/dev/sgx" ]]; then
    installSGXDrivers
fi
{{end}}

{{- if HasCustomSearchDomain}}
wait_for_file 3600 1 {{GetCustomSearchDomainsCSEScriptFilepath}} || exit $ERR_FILE_WATCH_TIMEOUT
{{GetCustomSearchDomainsCSEScriptFilepath}} > /opt/azure/containers/setup-custom-search-domain.log 2>&1 || exit $ERR_CUSTOM_SEARCH_DOMAINS_FAIL
{{end}}

configureK8s

{{- if not IsNoneCNI }}
configureCNI
{{end}}

{{/* configure and enable dhcpv6 for dual stack feature */}}
{{- if IsIPv6DualStackFeatureEnabled}}
ensureDHCPv6
{{- end}}

{{- if NeedsContainerd}}
ensureContainerd {{/* containerd should not be configured until cni has been configured first */}}
{{- else}}
ensureDocker
{{- end}}

ensureMonitorService
# must run before kubelet starts to avoid race in container status using wrong image
# https://github.com/kubernetes/kubernetes/issues/51017
# can remove when fixed
cleanupRetaggedImages

{{- if EnableHostsConfigAgent}}
configPrivateClusterHosts
{{- end}}

{{- if ShouldConfigTransparentHugePage}}
configureTransparentHugePage
{{- end}}

{{- if ShouldConfigSwapFile}}
configureSwapFile
{{- end}}

ensureSysctl
ensureJournal
{{- if IsKrustlet}}
systemctlEnableAndStart krustlet
{{- else}}
ensureKubelet
{{- if NeedsContainerd}} {{- if and IsKubenet (not HasCalicoNetworkPolicy)}}
ensureNoDupOnPromiscuBridge
{{- end}} {{- end}}
{{- end}}

if $FULL_INSTALL_REQUIRED; then
    if [[ $OS == $UBUNTU_OS_NAME ]]; then
        {{/* mitigation for bug https://bugs.launchpad.net/ubuntu/+source/linux/+bug/1676635 */}}
        echo 2dd1ce17-079e-403c-b352-a1921ee207ee > /sys/bus/vmbus/drivers/hv_util/unbind
        sed -i "13i\echo 2dd1ce17-079e-403c-b352-a1921ee207ee > /sys/bus/vmbus/drivers/hv_util/unbind\n" /etc/rc.local
    fi
fi

if [[ $OS == $UBUNTU_OS_NAME ]]; then
    apt_get_purge 20 30 120 apache2-utils &
fi

VALIDATION_ERR=0

{{- /* Edge case scenarios: */}}
{{- /* high retry times to wait for new API server DNS record to replicate (e.g. stop and start cluster) */}}
{{- /* high timeout to address high latency for private dns server to forward request to Azure DNS */}}
API_SERVER_DNS_RETRIES=100
if [[ $API_SERVER_NAME == *.privatelink.* ]]; then
  API_SERVER_DNS_RETRIES=200
fi
{{- if not EnableHostsConfigAgent}}
RES=$(retrycmd_if_failure ${API_SERVER_DNS_RETRIES} 1 10 nslookup ${API_SERVER_NAME})
STS=$?
{{- else}}
STS=0
{{- end}}
if [[ $STS != 0 ]]; then
    time nslookup ${API_SERVER_NAME}
    if [[ $RES == *"168.63.129.16"*  ]]; then
        VALIDATION_ERR=$ERR_K8S_API_SERVER_AZURE_DNS_LOOKUP_FAIL
    else
        VALIDATION_ERR=$ERR_K8S_API_SERVER_DNS_LOOKUP_FAIL
    fi
else
    API_SERVER_CONN_RETRIES=50
    if [[ $API_SERVER_NAME == *.privatelink.* ]]; then
        API_SERVER_CONN_RETRIES=100
    fi
    retrycmd_if_failure ${API_SERVER_CONN_RETRIES} 1 10 nc -vz ${API_SERVER_NAME} 443 || time nc -vz ${API_SERVER_NAME} 443 || VALIDATION_ERR=$ERR_K8S_API_SERVER_CONN_FAIL
fi

if $REBOOTREQUIRED; then
    echo 'reboot required, rebooting node in 1 minute'
    /bin/bash -c "shutdown -r 1 &"
    if [[ $OS == $UBUNTU_OS_NAME ]]; then
        aptmarkWALinuxAgent unhold &
    fi
else
    if [[ $OS == $UBUNTU_OS_NAME ]]; then
        /usr/lib/apt/apt.systemd.daily &
        aptmarkWALinuxAgent unhold &
    fi
fi

apply_unattended_upgrade_config

echo "Custom script finished. API server connection check code:" $VALIDATION_ERR
echo $(date),$(hostname), endcustomscript>>/opt/m
mkdir -p /opt/azure/containers && touch /opt/azure/containers/provision.complete
ps auxfww > /opt/azure/provision-ps.log &

exit $VALIDATION_ERR

#EOF
