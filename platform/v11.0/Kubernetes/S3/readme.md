This helmchart was created based of the documentation provided in https://bitnami.com/stack/minio/helm and 
https://github.com/bitnami/charts/blob/main/bitnami/minio.

Before running the script please verify and edit the values in values.yaml. If you need more customization for your S3 deployment please check https://github.com/bitnami/charts/blob/main/bitnami/minio/values.yaml.

helm install <releaseName> --namespace <namespace> oci://registry-1.docker.io/bitnamicharts/minio -f values.yaml --version 14.7.1
