This helmchart was created based of the documentation provided in https://bitnami.com/stack/kafka/helm and 
https://github.com/bitnami/charts/tree/main/bitnami/kafka. 

Before running the script please verify and edit the values in values.yaml.

helm install <releaseName> --namespace <namespace> oci://registry-1.docker.io/bitnamicharts/kafka -f values.yaml --version 30.0.4