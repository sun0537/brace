#!/bin/bash

# Function to display help message
show_help() {
    echo "Usage: $0 [-e|--encode] [-d|--decode] input_file [delimiter] [-h|--help]"
    echo
    echo "Options:"
    echo "  -e, --encode      Encode the input file contents using base64"
    echo "  -d, --decode      Decode the input file contents from base64"
    echo "  input_file        The input file to be processed"
    echo "  delimiter         The delimiter for separating content blocks in input file"
    echo "                    Options: ; , {} | @"
    echo "  -h, --help        Display this help message"
}

# Check if at least two arguments are provided
if [ "$#" -lt 2 ]; then
    show_help
    exit 1
fi

# Parse command line arguments
mode=""
input_file=""
delimiter="{}"
while [[ "$#" -gt 0 ]]; do
    case $1 in
        -e|--encode) mode="encode"; shift ;;
        -d|--decode) mode="decode"; shift ;;
        -h|--help) show_help; exit 0 ;;
        *) 
            if [[ -z "$input_file" ]]; then
                input_file="$1"
            elif [[ -z "$delimiter" ]]; then
                delimiter="$1"
            else
                echo "Invalid argument: $1"
                show_help
                exit 1
            fi
            shift
            ;;
    esac
done

# Validate required arguments
if [[ -z "$mode" || -z "$input_file" ]]; then
    show_help
    exit 1
fi

# Determine the actual delimiter to use
case $delimiter in
    ';') delimiter=';' ;;
    ',') delimiter=',' ;;
    '{}') delimiter='\{\}' ;;
    '|') delimiter='|' ;;
    '@') delimiter='@' ;;
    *) echo "Invalid delimiter: $delimiter"; show_help; exit 1 ;;
esac

# Function to encode content blocks using base64
encode() {
    local file="$1"
    local delim="$2"
    local output_file="${file}.encoded"
    rm -f "$output_file"

    if [ "$delim" = '\{\}' ]; then
	awk -v RS='}' -v ORS='' '{ if (NR > 1) printf "}?"; print $0 }' "$file" | while IFS= read -r -d '?' block; do
            # echo -n 打印信息不换行  -w 0 多少个字符后换行，0不换行
	    local encoded=$(echo -n "$block" | base64 -w 0)
	    echo "vmess://$encoded" >> "$output_file"
        done
    else
        awk -v RS="$delim" '{ print $0 RS}' "$file" | while read -r block; do
            local encoded=$(echo -n "$block" | base64 -w 0)
	    echo "vmess://$encoded" >> "$output_file"
        done
    fi
}

# Function to decode base64 encoded content blocks
decode() {
    local file="$1"
    local output_file="${file}.decoded"
    rm -f "$output_file"

    while read -r line; do
        echo "$line" | base64 --decode >> "$output_file"
        echo >> "$output_file"
    done < "$file"
}

# Execute the appropriate function based on the mode
if [ "$mode" = "encode" ]; then
    encode "$input_file" "$delimiter"
elif [ "$mode" = "decode" ]; then
    decode "$input_file"
else
    echo "Invalid mode: $mode"
    show_help
    exit 1
fi

echo "Operation completed successfully."

