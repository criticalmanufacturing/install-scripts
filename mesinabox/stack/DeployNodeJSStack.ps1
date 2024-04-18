oc apply --server-side --field-manager=devopscenter.criticalmanufacturing --force-conflicts -f nodetest-namespace.yaml
oc apply --server-side --field-manager=devopscenter.criticalmanufacturing --force-conflicts -f nodetest-deployment.yaml
oc apply --server-side --field-manager=devopscenter.criticalmanufacturing --force-conflicts -f nodetest-service.yaml
oc apply --server-side --field-manager=devopscenter.criticalmanufacturing --force-conflicts -f nodetest-ingress.yaml
oc apply --server-side --field-manager=devopscenter.criticalmanufacturing --force-conflicts -f nodetest-crb.yaml
oc apply --server-side --field-manager=devopscenter.criticalmanufacturing --force-conflicts -f nodetest-pv.yaml
oc apply --server-side --field-manager=devopscenter.criticalmanufacturing --force-conflicts -f nodetest-pvc.yaml