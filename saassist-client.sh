#!/bin/ksh
#
# saassist-client.ksh
#
# This is part of Security APAR Assistant (SAAssist)
#
#

version='0.1-beta'

if [ -f ./client_config ]; then
    . ./client_config
else
    echo "[ERROR] The 'client_config' file needs to be in"
    echo "the same directory of saassist-client"
    exit 1
fi

# Basic variables
server_version=$(oslevel -r)
server_release=$(oslevel -s | awk -F'-' '{ print $1"-"$2"-"$3 }')
server_url="http://$SAA_SERVER:$SAA_PORT/"
secid_url="$server_url$2/"
secid_url_version="$secid_url$server_version/"

# Function to check if SAA Server is ready using NFS
function _check_APAR_nfs {
        echo "[CLIENT] Verifying SAA Server over NFS"

        find_nfs=$(df -k | grep : | grep ${SAA_SERVER})
        if [ $? -ne 0 ]; then
            echo "[CLIENT] Filesystem ${SAA_FILESYTEM} not found"
            echo "[CLIENT] Trying to mount..."
            if [ ! -d ${SAA_FILESYSTEM} ]; then
                mkdir -p ${SAA_FILESYSTEM}
            fi
            mount ${SAA_SERVER}:${SAA_FILESYSTEM} ${SAA_FILESYSTEM}
            if [ $? -eq 0 ]; then
                echo "[CLIENT] Filesystem ${SAA_FILESYTEM} ready to be used"
            else
                echo "[ERROR] Please, check the NFS server or name resolution"
                exit 1
            fi
        fi
}

# Function to check if SAA Server is ready using HTTP
function _check_APAR_http {

    echo '[CLIENT] Verifying SAA Server over HTTP'

    # check if curl is installed, this required by HTTP Protocol
    curl_path='which curl'
    if [ $? -ne 0 ]; then
        echo '[ERROR] Command curl is required to use protocol HTTP'
        echo '        Please install curl, include on the PATH or try to use NFS '
        echo '        protocol on client_config'
    fi

    # test HTTP connection with SAA Server
    http_test=$(curl -o /dev/null -sSf ${server_url})

    if [ $? -ne 0 ]; then
        echo "[ERROR] HTTP Connection failed"
        exit 1
    else
        echo "[CLIENT] HTTP Connection OK"
    fi

}

function _check_tmp_dir {

    if [ ! -d $SAA_TMP_DIR ]; then
        echo "[ERROR] Check the client_config SAA_TMP_DIR."
        echo "        Directory doesn't exist."
    fi

    if [ ! -d $SAA_TMP_DIR/$1 ]; then
            mkdir -p $SAA_TMP_DIR/$1
    fi
}
# function to check CVE/IV on server
function _check_secid {

    # check
    if [ ${SAA_PROTOCOL} == 'http' ]; then
        secid_test=$(curl -o /dev/null -s -I -f ${secid_url})
        rc=$?
    fi

    if [ ${SAA_PROTOCOL} == 'nfs' ]; then
        secid_test=$(ls -ld ${SAA_FILESYSTEM}/$1)
        rc=$?
    fi

    if [ $rc -ne 0 ]; then
        echo "[CLIENT] The CVE/IV $1 is not available on server $SAA_SERVER."
        echo
        echo "         This APAR was not processed by SAAssist Server or not"
        echo "         exists."
        echo "         - Check if APAR ID $1 is correct"
        echo "         - Check with Security APAR Assistant server"
        echo "         administrator if that APAR is already available."
        echo
        exit 1

    else
        echo "[CLIENT] Retrieving APAR $1 info from ${SAA_SERVER}"
        echo "[CLIENT] Checking if CVE/IV is applicable for OS version $(oslevel -r)"
        if [ ${SAA_PROTOCOL} == 'http' ]; then
            secid_version_test=$(curl -o /dev/null -s -I -f ${secid_url_version})
            rc=$?
        fi

        if [ ${SAA_PROTOCOL} == 'nfs' ]; then
            secid_version_test=$(ls -ld ${SAA_FILESYSTEM}/$1/$server_version > /dev/null 2>&1)
            rc=$?
        fi

        if [ $rc -ne 0 ]; then
            echo "      \`- The version $(oslevel -r) is not affected by $1"
            system_affected='False'
        else
            echo "      \`- This server is affected by $1"
            if [ ${SAA_PROTOCOL} == 'http' ]; then
                curl -s ${secid_url_version}/$1.info -o ${SAA_TMP_DIR}/$1/$1.info
                rc=$?
            fi

            if [ ${SAA_PROTOCOL} == 'nfs' ]; then
                cp ${SAA_FILESYSTEM}/$1/$server_version/$1.info ${SAA_TMP_DIR}/$1/$1.info > /dev/null 2>&1
                rc=$?
            fi

            if [ $rc -ne 0 ]; then
                echo "[ERROR] Failed to saved the $1.info file"
                exit 1
            fi
            . /${SAA_TMP_DIR}/$1/$1.info
            system_affected='True'

        fi

        if [ $system_affected == 'True' ]; then
            echo "[CLIENT] Checking if CVE/IV is applicable for OS release $server_release"
            for release in ${AFFECTED_RELEASES}; do
                if [ "$release" == "$server_release" ]; then
                    system_affected='True'
                fi
            done

            if [ "$system_affected" == 'False' ]; then
                echo "      \`- $server_release is not affected by $1"
            else
                echo "      \`- $server_release is affected by $1"
            fi
        fi

        if [ $system_affected == 'True' ]; then
            echo "[CLIENT] Checking if there are APARs already applied"
            for iv in ${REMEDIATION_APARS}; do
                if [ $(echo $1 | cut -c1-2) == "IV" ]; then
                    iv_ver="$(echo $AFFECTED_RELEASES | awk '{ print $1 }' | cut -c1).$(echo $AFFECTED_RELEASES | awk '{ print $1 }' | cut -c2)"
                else
                    iv_ver=$(echo "$iv" | awk -F. '{ print $1"."$2 }')
                fi
                os_ver=$(oslevel | awk -F'.' '{ print $1"."$2 }')
                if [ "$iv_ver" == "$os_ver" ]; then
                    if [ $(echo $1 | cut -c1-2) == "IV" ]; then
                        apar_name=$1
                    else
                        apar_name=$(echo ${iv} | /usr/bin/awk -F':' '{ print $2 }')
                    fi
                    instfix -ik "$apar_name" > /dev/null 2>&1
                    if [ $? -eq 0 ]; then
                        echo "      \`- $apar_name is already installed"
                        system_affected='False'
                    else
                        echo "      \`- $apar_name is NOT installed"
                        system_affected='True'
                        break
                    fi
                fi
            done
        fi

        if [ ${system_affected} == "True" ]; then
            echo "[CLIENT] This system is AFFECTED by $1"
            echo "      \`- Downloading APAR to $SAA_TMP_DIR"
            for apar in ${APAR_FIX}; do
                apar_fix=$(echo $apar | awk -F'/' '{ print $NF }')

                if [ ${SAA_PROTOCOL} == 'http' ]; then
                    curl -s $secid_url_version/$apar_fix -o $SAA_TMP_DIR/$1/$apar_fix
                    rc=$?
                fi

                if [ ${SAA_PROTOCOL} == 'nfs' ]; then
                    cp ${SAA_FILESYSTEM}/$1/$server_version/$apar_fix ${SAA_TMP_DIR}/$1/$apar_fix > /dev/null 2>&1
                    rc=$?
                fi


                if [ $rc -ne 0 ]; then
                    echo "[ERROR] Failed to download ${apar_fix}"
                    exit 1
                fi
            done

                apar_fix=$(echo $apar | awk -F'/' '{ print $NF }')
                apar_dir=$(echo $apar_fix | awk -F'.' '{ print $1 }')
                cd ${SAA_TMP_DIR}/$1
                if [ $(echo $apar_fix | awk -F'.' '{ print $NF }') == 'tar' ]; then
                    tar xvf $apar_fix > /dev/null 2>&1
                    cd $apar_dir
                fi

                for file in $(ls | grep epkg.Z | grep -v sig); do
                    echo "      \`- Running a $file preview "
                    preview_cmd=$(emgr -p -e $file 2> /dev/null)
                    if [ $? -eq 0 ]; then
                        echo "      \`- APAR $file is APPLICABLE to the system"
                        system_affected='True'
                        if [ $2 != 'install' ]; then
				break
			fi

                    else
                        echo "      \`- APAR $file is NOT applicable to the system"
                        system_affected='False'
                        #emgr -p -e $file 2> /dev/null| grep -p "Prerequisite Number:"

                    fi
                done
        fi

    fi

}

function _check_protocols {
    if [ ${SAA_PROTOCOL} == 'http' ]; then
        _check_APAR_http
    fi

    if [ ${SAA_PROTOCOL} == 'nfs' ]; then
        _check_APAR_nfs
    fi

}
function APAR_info  {

    if [ ${system_affected} == "True" ]; then
        echo "[CLIENT] This system is AFFECTED by $1"
        echo "[CLIENT] Getting APAR '$1' info"
        if [ ${system_affected} == "True" ]; then

            if [ ${SAA_PROTOCOL} == 'http' ]; then
                sleep 2
                curl -L ${secid_url_version}/${APAR_ASC} | more
            fi

            if [ ${SAA_PROTOCOL} == 'nfs' ]; then
                more ${SAA_FILESYSTEM}/$1/$server_version/${APAR_ASC}
            fi

        fi
    else
        echo "[CLIENT] This system is NOT AFFECTED by $1"
    fi


}

function APAR_check  {

    if [ ${system_affected} == "True" ]; then
        echo "[CLIENT] This system is AFFECTED by $1"
    else
        echo "[CLIENT] This system is NOT AFFECTED by $1"
        exit 1
    fi
}

function APAR_install {

    if [ ${system_affected} == "True" ]; then
        echo "[CLIENT] Starting the APAR $1 in 10 seconds. Use CTRL+C to cancel now!"
        sleep 10
        for apar in ${APAR_FIX}; do
            apar_fix=$(echo $apar | awk -F'/' '{ print $NF }')
            if [ $? -ne 0 ]; then
                echo "[ERROR] Failed to download ${apar_fix}"
                exit 1
            fi
        done

            apar_fix=$(echo $apar | awk -F'/' '{ print $NF }')
            apar_dir=$(echo $apar_fix | awk -F'.' '{ print $1 }')
            cd ${SAA_TMP_DIR}/$1
            if [ $(echo $apar_fix | awk -F'.' '{ print $NF }') == 'tar' ]; then
                cd $apar_dir
            fi

            for file in $(ls | grep epkg.Z | grep -v sig); do
                echo "      \`- Running a $file install preview/test "
                preview_cmd=$(emgr -p -e $file 2> /dev/null)
                if [ $? -eq 0 ]; then
                    echo "      \`- APAR $file is APPLICABLE to the system"
                    emgr -p -X $file
                else
                    echo "      \`- APAR $file is NOT applicable to the system"
                fi
            done
    else
        echo "[CLIENT] This system is NOT AFFECTED by $1"
        exit 1
    fi


}

function _print_help {

    echo 'Usage: saassist-client [check|info|install] "CVE|IV-NUM" | help'
    echo
    echo 'check   : Verify if the system is affected by CVE/IV'
    echo 'info    : Open the details about the CVE/IV if system is affected'
    echo 'install : Install the APAR if it is available and applicable to the'
    echo '          the system'
    echo
    echo 'Example:'
    echo '  saassist-client check "CVE-2016-0281"'
    echo '  saassist-client check "IV91004"'
    echo
    echo 'It requires the client_config properly configured and a Security APAR'
    echo 'Assistant server.'
    echo 'It works over HTTP and NFS protocols, please check the README for'
    echo 'more information.'
    echo

}


#
# Main
#

echo
echo "========================================================================"
echo "SAAssist-client (Security APAR Assist Client) - Version $version"
echo "========================================================================"
echo
echo "Current OS Version: $(oslevel -s)"
echo
if [ -z $2 ]; then
    echo "[ERROR] A CVE or IV is required"
    echo
    _print_help
    exit 1
fi

case $1 in

    'check')

        _check_tmp_dir $2
        _check_protocols
        _check_secid $2 $1
	echo
        APAR_check $2



    ;;

    'info')

        _check_tmp_dir $2
        _check_protocols
        _check_secid $2 $1
        echo
        APAR_info $2

    ;;

    'install')

        _check_tmp_dir $2
        _check_protocols
        _check_secid $2 $1
        echo
        APAR_install $2

    ;;

    *)

        _print_help

    ;;
esac