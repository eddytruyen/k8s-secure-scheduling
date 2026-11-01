# Widen ONLY the kube-apiserver livenessProbe in the kubeadm static pod
# manifest. Leaves readinessProbe/startupProbe untouched: a readiness
# failure just drops the endpoint, it does not kill the container.
/^    livenessProbe:/ { inlp = 1; print; next }
inlp && /^    [a-zA-Z]/ { inlp = 0 }
inlp && /failureThreshold:/ { sub(/failureThreshold: .*/, "failureThreshold: 20") }
inlp && /timeoutSeconds:/  { sub(/timeoutSeconds: .*/,  "timeoutSeconds: 5") }
{ print }
