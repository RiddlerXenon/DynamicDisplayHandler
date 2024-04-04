#!/bin/bash

# ddh - Dynamic Display Handler
# Author: Riddler Xenon

trap "exit" SIGINT SIGTERM # Signal handling

version="1.0.2" # Script version

declare -A config # Associative array to store config values

# Default config file
config_file="$HOME/.config/ddh/config.ini"
ac_dir=$(ls /sys/class/power_supply/ | grep -P "AC")


# Function to read config file
function read_config() {
    section=""
    while IFS= read -r line; do
        if [[ $line =~ ^\[.*\]$ ]]; then
            section="${line#[}"
            section="${section%]}"
            continue
        fi

        if [[ $section == "display" ]] || [[ $section == "power" ]]; then
            if [[ $line =~ .*=.* ]]; then
                key="${line%%=*}"
                value="${line#*=}"
                config[$key]="$value"
            fi
        fi
    done < "$config_file"
}

# Parse command line arguments
while (( "$#" )); do
  case "$1" in
    -c|--config)
      if [ -n "$2" ] && [ ${2:0:1} != "-" ]; then
        config_file=$2
        shift 2
      else
        printf "Error: Argument for %s is missing\n" "$1" >&2
        exit 1
      fi
      ;;
    -v|--version)
      printf "ddh version: %s\n" "$version"
      exit 0
      ;;
    -h|--help)
      printf "Usage: ddh [OPTIONS]\n"
      printf "Options:\n"
      printf "  -c, --config FILE\t\tSpecify config file\n"
      printf "  -v, --version\t\t\tPrint version\n"
      printf "  -h, --help\t\t\tPrint help\n"
      exit 0
      ;;
    -*|--*=) 
      printf "Error: Unsupported flag %s\n" "$1" >&2
      exit 1
      ;;
    *) 
      PARAMS="$PARAMS $1"
      shift
      ;;
  esac
done

eval set -- "$PARAMS" # Set positional arguments in their proper place

# Check if config file exists
if [ ! -f "$config_file" ]; then
    printf "Config file not found: %s\n" "$config_file"
    config_file="$HOME/.config/ddh/config.ini"
fi

printf "Using config file: %s\n" "$config_file" # Check if config file exists

while true; do
    read_config # Read config file
    
    # Store config values in variables
    resolutions=(${config[RESOLUTIONS]})
    refresh_rates=(${config[REFRESH_RATES]})
    max_refresh_rates=(${config[MAX_REFRESH_RATES]})
    displays=(${config[DISPLAYS]})
    
    # Get current power status and connected displays
    current_power=$(< /sys/class/power_supply/$ac_dir/online)
    current_displays=($(xrandr -q | awk '/ connected / {print $1}'))

    # Check if the current displays are the same as the config file
    # If not, set the displays to the config file values
    if [[ ${current_displays[*]} != ${displays[*]} ]]; then
        declare -A nresolutions
        declare -A nrefresh_rates
        declare -A nmax_refresh_rates

        for index in "${!current_displays[@]}"; do
            display=${current_displays[$index]}
            max_resolution=$(xrandr | grep -P "^$display" -A1 | tail -n1 | awk '{print $1}')
            rates=($(xrandr -q | grep -P "^$display" -A1 | tail -n 1 | awk '{$1=""; print $0}' | sed 's/^ *//' | tr -dc '0-9. '))
            max_refresh_rate=$(echo ${rates[@]} | tr ' ' '\n' | sort -n | tail -n 1)

            closest_refresh_rate=$(echo ${rates[@]} | tr ' ' '\n' | sort -n | awk -v target=60 'function abs(x){return ((x < 0) ? -x : x)} BEGIN{min=1e9}{
                if (abs($1-target)<min) {
                    min=abs($1-target)
                    val=$1
                }
            }END{print val}')

            abs() {
                if [ $1 -lt 0 ]; then
                    echo "$((-1 * $1))"
                else
                    echo "$1"
                fi
            }
            
            nresolutions[$display]=$max_resolution
            nrefresh_rates[$display]=$closest_refresh_rate
            nmax_refresh_rates[$display]=$max_refresh_rate

            pos=${config[DISPLAYS_POSITIONS]}

            if [[ $index != 0 ]]; then
                if [[ $pos == "right-of" ]]; then
                    xrandr --output "$display" --mode "${max_resolution}" --rate "${max_refresh_rate}" --right-of "${displays[index-1]}"
                else
                    xrandr --output "$display" --mode "${max_resolution}" --rate "${max_refresh_rate}" --left-of "${displays[index-1]}"
                fi
            else
                xrandr --output "$display" --mode "${max_resolution}" --rate "${max_refresh_rate}" --primary
            fi
        done

        nresolutions_rev=($(echo ${nresolutions[*]} | tr ' ' '\n' | tac | tr '\n' ' '))
        nrefresh_rates_rev=($(echo ${nrefresh_rates[*]} | tr ' ' '\n' | tac | tr '\n' ' '))
        nmax_refresh_rates_rev=($(echo ${nmax_refresh_rates[*]} | tr ' ' '\n' | tac | tr '\n' ' '))

        sed -i "s/DISPLAYS=.*$/DISPLAYS=${current_displays[*]}/" "$config_file"
        sed -i "s/RESOLUTIONS=.*$/RESOLUTIONS=${nresolutions_rev[*]}/" "$config_file"
        sed -i "s/REFRESH_RATES=.*$/REFRESH_RATES=${nrefresh_rates_rev[*]}/" "$config_file"
        sed -i "s/MAX_REFRESH_RATES=.*$/MAX_REFRESH_RATES=${nmax_refresh_rates_rev[*]}/" "$config_file"
    fi

    # Check if the current power status is the same as the config file
    # If not, set the power status to the config file value
    if [[ $current_power != ${config[AC]} ]]; then
        index=0

        # Set the display resolution and refresh rate based on the power status
        # and set the brightness based on the power status
        if [[ $current_power == "1" ]]; then
            for display in "${current_displays[@]}"; do
                xrandr --output "$display" --mode "${resolutions[index]}" --rate "${max_refresh_rates[index]}"
                ((index++))
            done
            xbacklight -set "${config[AC_BRIGHTNESS]}"
        else
            for display in "${current_displays[@]}"; do
                xrandr --output "$display" --mode "${resolutions[index]}" --rate "${refresh_rates[index]}"
                ((index++))
            done
            xbacklight -set "${config[BATTERY_BRIGHTNESS]}"
        fi
        sed -i "s/AC=.*$/AC=$current_power/" "$config_file"
    fi

    sleep 3 # Sleep for 3 seconds
done
