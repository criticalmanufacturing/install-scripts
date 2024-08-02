#!/bin/sh

# Check if the input file is provided
if [ -z "$1" ]; then
  echo "Usage: $0 <file>"
  exit 1
fi

FILE=$1

# Check if the file exists
if [ ! -f "$FILE" ]; then
  echo "File not found: $FILE"
  exit 1
fi

for var in $(env); do
  key=${var%%=*}
  value=${var#*=}

  echo "Replacing \${$key} with ${value}"
  sed -i "s|\${${key}}|${value}|g" "$FILE"
done