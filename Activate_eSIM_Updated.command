#!/bin/zsh
PATH=/bin:/usr/bin:/sbin:/usr/sbin:/usr/local/bin: export PATH
#set -xv


###################
#Define Settings
###################

VER="0.2" # Script version number, note the single decimal point

HOST_ADDRESS="10.2.1.6" #Web server host, including port number if not 80. Do not include http://
UPDATE_SERVER="10.2.1.6" # Where is the update server for automatic updates of this script

####################### Gather order information #######################

#Get the unit's serial number. We are using the first iPad to respond's serial number for order lookup
SERIAL=$(cfgutil get serialNumber)
until [ ! -z ${SERIAL} ]; do
	echo "Waiting on iPad"
	sleep 5
	SERIAL=$(cfgutil get serialNumber 2> /dev/null)
done
echo "Serial number is: $SERIAL"

#Get the unit's PO number for lookup
ENC_SERIAL=$(echo "##&query=systemSearch&STRING=${SERIAL}&##" |base64 )
DEP_INFO=$(curl "https://secure.crest-tech.net/admin/ai/dnaquery.tpl?${ENC_SERIAL}" | base64 -D | awk -F "%3D" {'print $12'} |awk -F "%2" {'print $1'})

#Download encrypted password and data from server
secret=$(curl -s http://${HOST_ADDRESS}/dc_config/${DEP_INFO}.txt |grep "MDM_PASS" |awk {'print $2'})
JAMF_USER=$(curl -s http://${HOST_ADDRESS}/dc_config/${DEP_INFO}.txt |grep "MDM_USER" |awk {'print $2'})
JAMF_URL=$(curl -s http://${HOST_ADDRESS}/dc_config/${DEP_INFO}.txt |grep "MDM_URL" |awk {'print $2'})
ESIM_URL=$(curl -s http://${HOST_ADDRESS}/dc_config/${DEP_INFO}.txt |grep "ESIM_URL" |awk {'print $2'})

# Decrypt downloaded password

JAMF_PASS=$(echo "${secret}" | openssl enc -d -aes-128-cbc -k "CREST-UPW-salt" -base64)

#################################################################################

MDM="jamf" # Supported MDMs are - jamf
PHONE_NUMBER_VERIFICATION="on" # Whether this script will verify the cellular data number on devices before considering eSIM as active - possible values "on" "off". Verification can take a while.
MINUTES_TO_WAIT_FOR_PHONE_NUMBER="10" # Minutes to wait for CDN when PHONE_NUMBER_VERIFICATION is "on"
SECONDS_TO_WAIT_BETWEEN_ACTIVATIONS="5" # eSIM activations should be staggered as not to overwhelm carrier services.

##################### DO NOT EDIT BELOW THIS LINE ###############################
#################################################################################

dependency_check()
{
	if [[ ! -f "/Applications/Apple Configurator.app/Contents/MacOS/cfgutil" ]]; then
		echo "Apple Configurator 2 is not installed in the Applications folder."
		exit 1
	else
		cfgutil="/Applications/Apple Configurator.app/Contents/MacOS/cfgutil"
	fi

	if [[ ! -f "/usr/local/bin/jq" ]]; then
		echo "Install 'jq' in /usr/local/bin/."
		exit 1
	fi

	if [[ "$ESIM_URL" == "" ]]; then
		echo "eSIM URL is not populated."
		exit 1
	fi

	valid_url='(https?)://[-A-Za-z0-9\+&@#/%?=~_|!:,.;]*[-A-Za-z0-9\+&@#/%=~_|]'
	if [[ ! "$ESIM_URL" =~ $valid_url ]]; then
		echo "eSIM URL is not valid."
		exit 1
	fi
	#Remove trailing slash if present
	ESIM_URL=${ESIM_URL%/}

	if [[ "$PHONE_NUMBER_VERIFICATION" != "on" && "$PHONE_NUMBER_VERIFICATION" != "off" ]]; then
		echo "Set PHONE_NUMBER_VERIFICATION to 'on' or 'off'."
		exit 1
	fi

	if [[ "$MDM" != "jamf" && "$MDM" != "test" ]]; then
		echo "Set a supported MDM."
		exit 1
	fi
}

setup_status()
{
	STATUS_DIR=$(mktemp -d /private/tmp/APS_eSIM.XXXXXX)
	STATUS=$(mktemp "$STATUS_DIR"/esim_status.XXXXXX)

	printf 'eSIM Server URL: %s\nDevices Attached:\n\n' "$ESIM_URL" >> "$STATUS"
	printf '%-12s\t%-25s\t%-60s\n' "Serial" "Name" "Status" >> "$STATUS"
	visual_layout
}


update_status()
{
	# $1 is name $2 is serial $3 is status
	#sed -i -e $'s/^'$1'.*/'$1'	'$2'	'$3'/g' "$STATUS"
	local newline=$(printf '%-12s\t%-25s\t%-60s\n' "${1:0:12}" "${2:0:25}" "${3:0:60}")
	sed -i -e $'s/^'$1'.*/'$newline'/g' "$STATUS"
	visual_layout
}

visual_layout()
{
	clear; cat "$STATUS"
}

update_serial()
{
	local ecid=$1
	local old_serial=$2
	local new_serial=$(cfgutil -e "$ecid" get serialNumber)
	sed -i -e $'s/^'$old_serial'.*/'$new_serial'/g' "$STATUS"
	visual_layout
}

serial_to_ecid()
{
	local ecid=$1
	local old_serial=$2
	sed -i -e $'s/^'$old_serial'.*/'$ecid'/g' "$STATUS"
	visual_layout
}

gather_devices()
{
	ATTACHED_DEVICES=$(mktemp -q "$STATUS_DIR"/esim_devices.XXXXXX)
	echo "Gathering connected devices"
	cfgutil --format JSON list > "$ATTACHED_DEVICES"
	ATTACHED_ECIDS_ARRAY=(`cat "$ATTACHED_DEVICES" | jq --raw-output '."Output"[].ECID'`)

	qty_devices=${#ATTACHED_ECIDS_ARRAY[@]}
	sed -i -e $' s/^Devices Attached:/Devices Attached: '$qty_devices'/' "$STATUS"
	visual_layout

	for ecid in "${ATTACHED_ECIDS_ARRAY[@]}"; do
		mktemp "$STATUS_DIR"/esim_"$ecid"
	done

	for ecid in "${ATTACHED_ECIDS_ARRAY[@]}"; do
		local ecid_file="$STATUS_DIR"/esim_"$ecid"
		cfgutil --format JSON -e $ecid get isPaired activationState serialNumber name IMEI phoneNumber > "$ecid_file"
		local device_serial=$(jq --raw-output '.Output."'$ecid'".serialNumber' "$ecid_file")
		local device_name=$(jq --raw-output '.Output."'$ecid'".name' "$ecid_file")
		local device_status=""
		printf '%-12s\t%-25s\t%-60s\n' "${device_serial:0:12}" "${device_name:0:25}" "${device_status:0:60}" >> "$STATUS"
		visual_layout
		
		#Not paired
		if [[ $(jq --raw-output '.Output."'$ecid'".isPaired' "$ecid_file") == "false" ]] && [[ "$device_serial" == "null" ]]; then
			update_status "$device_serial" "$device_name" "Error - Accept pairing request on device"
			local loop=0
			local loop_max=60 #Allow about a minute to enable pairing
			until [[ $loop -eq $loop_max ]] || [[ $(jq --raw-output '.Output."'$ecid'".isPaired' "$ecid_file") == "true" ]]; do
				cfgutil --format JSON -e $ecid get isPaired activationState serialNumber name IMEI phoneNumber > "$ecid_file"
				((loop++))
			done
			
			if [[ $loop -ge $loop_max ]]; then
				serial_to_ecid "$ecid" "$device_serial"
				update_status "$ecid" "$device_name" "Error - Did not pair, ECID $ecid"
				ATTACHED_ECIDS_ARRAY[$ATTACHED_ECIDS_ARRAY[(i)$ecid]]=() #remove from array
			else
				update_serial "$ecid" "$device_serial"
				local device_status="Connected"
			fi
		
		#Not enrolled.
		elif [[ $(jq --raw-output '.Output."'$ecid'".activationState' "$ecid_file") == "Unactivated" ]] && [[ "$device_serial" != "null" ]]; then
			local device_status="Error - Device not activated or enrolled in MDM. Skipping."
			update_status "$device_serial" "$device_name" "$device_status"
			ATTACHED_ECIDS_ARRAY[$ATTACHED_ECIDS_ARRAY[(i)$ecid]]=() #remove from array
		
		#Other error and cant read the serial.
		elif [[ "$device_serial" == "null" ]]; then
			error=$(jq --raw-output '.Output.Errors."'$ecid'".serialNumber.Message' "$ecid_file")
			echo "Error - $error" >> "$STATUS"; visual_layout
			cleanup
			exit 2
		
		#No issues
		else
			local device_status="Connected"
		fi


		if [[ "$device_status" = "Connected" ]]; then
			update_status "$device_serial" "$device_name" "$device_status"
		fi
	done

	#Checks to add for cfgutuil: activationState = Activated, isPaired
}

mdm_main()
{
	
	if [[ -z ${ATTACHED_ECIDS_ARRAY[@]} ]]; then
		echo "No devices to configure." >> "$STATUS"; visual_layout
		cleanup
		exit 2
	elif [[ "$MDM" == "jamf" ]]; then
		jamf_verify
		jamf_activate_esim
	elif [[ "$MDM" == "test" ]]; then
		for ecid in "${ATTACHED_ECIDS_ARRAY[@]}"; do
			local ecid_file="$STATUS_DIR"/esim_"$ecid"
			device_name=$(jq --raw-output '.Output."'$ecid'".name' "$ecid_file")
			serial_number=$(jq --raw-output '.Output."'$ecid'".serialNumber' "$ecid_file")
			update_status "$serial_number" "$device_name" "This is only a test"
			sleep .5
		done
	fi
}

jamf_verify()
{
	if [[ "$JAMF_URL" == "" ]]; then
		echo "Jamf URL is not populated." > "$STATUS"; visual_layout
		cleanup
		exit 3
	fi

	valid_url='(https?)://[-A-Za-z0-9\+&@#/%?=~_|!:,.;]*[-A-Za-z0-9\+&@#/%=~_|]'
	if [[ ! "$JAMF_URL" =~ $valid_url ]]; then
		echo "Jamf URL is not valid." > "$STATUS"; visual_layout
		cleanup
		exit 3
	fi

		if [[ "$JAMF_USER" == "" ]]; then
		echo "Jamf user is not populated." > "$STATUS"; visual_layout
		cleanup
		exit 3
	fi	

	if [[ "$JAMF_PASS" == "" ]]; then
		echo "Jamf password is not populated." > "$STATUS"; visual_layout
		cleanup
		exit 3
	fi

	#Remove trailing slash if present
	JAMF_URL=${JAMF_URL%/}

	#Add test for user access to Jamf
	curl --silent --connect-timeout 10 --user "$JAMF_USER":"$JAMF_PASS" --request GET "$JAMF_URL/JSSResource/accounts/username/$JAMF_USER" -H "accept: application/json" | jq .account.privileges.jss_actions | grep "Send Mobile Device Refresh Cellular Plans Command"
	if [[ $? -ne 0 ]]; then
		echo "Jamf credentials not correct or need privileges to send mobile device commands." > "$STATUS"; visual_layout
		cleanup
		exit 3
	fi

}

jamf_activate_esim(){

	verify_pids=()

	for ecid in "${ATTACHED_ECIDS_ARRAY[@]}"; do
		local ecid_file="$STATUS_DIR"/esim_"$ecid"
		device_name=$(jq --raw-output '.Output."'$ecid'".name' "$ecid_file")
		serial_number=$(jq --raw-output '.Output."'$ecid'".serialNumber' "$ecid_file")
		update_status "$serial_number" "$device_name" "Looking up device in Jamf"
		sleep .5
		jamf_id=$(curl --silent --connect-timeout 10 --user "$JAMF_USER":"$JAMF_PASS" --request GET "$JAMF_URL/JSSResource/mobiledevices/match/$serial_number" -H "accept: application/json" | jq '.mobile_devices[0].id')
		if [[ "$jamf_id" == "null" ]]; then
			update_status "$serial_number" "$device_name" "Not found in Jamf"
			break
		fi
		jamf_request_xml="<?xml version=\"1.0\" encoding=\"UTF-8\"?><mobile_device_command><general><command>RefreshCellularPlans</command><e_sim_server_url>$ESIM_URL</e_sim_server_url></general><mobile_devices><mobile_device><id>$jamf_id</id></mobile_device></mobile_devices></mobile_device_command>"
		curl --silent --connect-timeout 10 --user "$JAMF_USER":"$JAMF_PASS" --request POST  "$JAMF_URL/JSSResource/mobiledevicecommands/command" -H "accept: application/xml" -H "Content-Type: application/xml" -d "$jamf_request_xml"
		update_status "$serial_number" "$device_name" "Activating eSIM"
		sleep 5
		(verify_cdn "$ecid")& verify_pids+=($!) #Do verification in subshell for parallel tasks, add pid of subshell to array "verify_pids"
	done
}

verify_cdn()
{

if [[ "$PHONE_NUMBER_VERIFICATION" == "on" ]]; then
	ecid=$1
	local ecid_file="$STATUS_DIR"/esim_"$ecid"
	for (( i = 0; i <= $MINUTES_TO_WAIT_FOR_PHONE_NUMBER; i++ )); do
		cfgutil --format JSON -e $ecid get serialNumber name IMEI phoneNumber > "$ecid_file"
		phone_number=$(jq --raw-output '.Output."'$ecid'".phoneNumber' "$ecid_file")
		serial_number=$(jq --raw-output '.Output."'$ecid'".serialNumber' "$ecid_file")
		device_name=$(jq --raw-output '.Output."'$ecid'".name' "$ecid_file")
		if [[ $i -eq $MINUTES_TO_WAIT_FOR_PHONE_NUMBER ]]; then
			update_status "$serial_number" "$device_name" "Error - No CDN. Check device for eSIM."
			break
		elif [[ "$phone_number" == "null" ]]; then
			update_status "$serial_number" "$device_name" "Waiting for phone number (CDN or MSISDN)"
			sleep 60
		else
			update_status "$serial_number" "$device_name" "Complete - CDN: $phone_number"
			break
		fi

	done
else
	cfgutil --format JSON -e $ecid get serialNumber name IMEI phoneNumber > "$ecid_file"
	serial_number=$(jq --raw-output '.Output."'$ecid'".serialNumber' "$ecid_file")
	device_name=$(jq --raw-output '.Output."'$ecid'".name' "$ecid_file")
	update_status "$serial_number" "$device_name" "$serial_number" "Sent eSIM activation. Verify disabled."
fi

}

cleanup()
{

	for pid in "${verify_pids[@]}"; do
		if wait $pid; then
        else
            sleep 10
        fi
	done

	printf '%s\n'  >> "$STATUS" ; visual_layout
	printf "Script complete." >> "$STATUS" ; visual_layout

	rm -rf "$STATUS_DIR"

}

main()
{
dependency_check
setup_status
gather_devices
mdm_main
cleanup
}

#Resize window for additional output
printf '\033[8;35;110t'

main
exit 0
