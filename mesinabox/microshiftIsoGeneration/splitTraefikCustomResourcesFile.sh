#!/bin/bash

# GitHub file URL
github_url="https://raw.githubusercontent.com/traefik/traefik/v2.10/docs/content/reference/dynamic-configuration/kubernetes-crd-definition-v1.yml"

output_dir="edge-demos/demos/microshift-disconnected/files/manifests/traefikresources"

curl -sS "$github_url" -o "temp.yml"

mkdir -p "$output_dir"

csplit --quiet --prefix="$output_dir/resource_" --suffix-format="%02d" "temp.yml" "/---/" "{*}" --suppress-matched

for file in "$output_dir"/*; do
    mv "$file" "$file.yaml"
done
rm "temp.yml"

last_file="$output_dir/resource_00.yaml"
if [ ! -s "$last_file" ]; then
    rm "$last_file"
fi

echo "YAML files created in '$output_dir' directory."
