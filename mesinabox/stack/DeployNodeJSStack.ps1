oc apply --server-side --field-manager=devopscenter.criticalmanufacturing --force-conflicts -f namespace.yaml
oc apply --server-side --field-manager=devopscenter.criticalmanufacturing --force-conflicts -f deployment.yaml
oc apply --server-side --field-manager=devopscenter.criticalmanufacturing --force-conflicts -f service.yaml
oc apply --server-side --field-manager=devopscenter.criticalmanufacturing --force-conflicts -f ingress.yaml
oc apply --server-side --field-manager=devopscenter.criticalmanufacturing --force-conflicts -f crb.yaml
oc apply --server-side --field-manager=devopscenter.criticalmanufacturing --force-conflicts -f pvc.yaml
