#!/bin/sh
## This script will download an encrypted password from a file on the indicated server
## based on the unit's Purchase Order number, decrypt the password and run the QC Script
##
## Passwords must be encrypted using the following command:
##     echo "password" |openssl enc -aes-128-cbc -k "CREST-UPW-salt" -base64
## where "password" is the user's password. Then save the resulting data in the
## info.xt file for that PO number as PW <resultant key>

#	2022-06-10	0.2	Mark Gabrenas	Added code to lookup computer by PO number and get password from server

VER="0.2" # Launcher version number, note the single decimal point

HOST_ADDRESS="10.2.1.6" #Web server host, including port number if not 80. Do not include http://
UPDATE_SERVER="10.2.1.6" # Where is the update server for automatic updates of this script

####################### Functions ##########################
check_for_updates() 
{
## Autoupdate functionality.
## This will check the script for updates from a central location and then, if an update is available, download the updated script and re-run

SCRIPT_PATH=$(readlink -f "$0")

SCRIPT_NAME=`echo ${SCRIPT_PATH} |awk -F "/" {'print $NF'}`
echo "Script name is ${SCRIPT_NAME}"

# Get the version from the script on the server
FULL_SERVER="http://${UPDATE_SERVER}/dc_config/${SCRIPT_NAME}"
if curl -s ${FULL_SERVER} |grep "404"; then
	echo "There is no version of the script on the server. Continuing wihout updating."
else
	CHECK_VERSION=$(curl -s ${FULL_SERVER} |grep "VER=" |awk -F "\"" {'print $2'} )

#	Compare the two versions and update if needed
	if [ ${VER} -lt ${CHECK_VERSION} ]; then
		echo_green "There is a newer script on the server, updating."
		curl -s http://${UPDATE_SERVER}/dc_config/${SCRIPT_NAME} > /tmp/2_QC.temp
		if [ $? = 0 ];then
			echo_green "Downloaded updated script successfully. Moving into location"
			mv -f /tmp/2_QC.temp ${SCRIPT_PATH}
			if [ $? = 0 ]; then
				echo_green "Moved updated script successfully. Marking as executable"
				chmod +x ${SCRIPT_PATH}
				if [ $? = 0 ]; then
					echo_green "Successfully marked updated script as executable. Restarting Script"
					open ${SCRIPT_PATH} &
					exit 0
				else
					echo_red "Could not mark new script as executable. Exiting"
					exit 1
				fi
			else
				echo_red "Could not move script to proper location. Exiting."
				exit 1
			fi
		else
			echo_red "Could not download updated script"
			exit 1
			fi
		echo_green "Script was updated successfully"
	else
		echo "This version is the same or newer, continuing"
	fi
fi
}

####################### Main Laucher #######################
#Check to see if there are updates to this script
check_for_updates

#Get the unit's serial number
SERIAL=$(ioreg -l -x -w200 |grep "IOPlatformSerialNumber" |awk -F "\"" {'print $4'})
echo "Serial number is: $SERIAL"

#Get the unit's PO number for lookup
ENC_SERIAL=$(echo "##&query=systemSearch&STRING=${SERIAL}&##" |base64 )
DEP_INFO=$(curl "https://secure.crest-tech.net/admin/ai/dnaquery.tpl?${ENC_SERIAL}" | base64 -D | awk -F "%3D" {'print $12'} |awk -F "%2" {'print $1'})

#Download encrypted password from server
secret=$(curl -s http://${HOST_ADDRESS}/dc_config/${DEP_INFO}.txt |grep "PW" |awk {'print $2'})

# Decrypt downloaded password

PW=$(echo "${secret}" | openssl enc -d -aes-128-cbc -k "CREST-UPW-salt" -base64)

#Run the QC script with the resulant password
echo "${PW}" | sudo -S /Volumes/auto_Restore/2_QC.sh

exit 0
