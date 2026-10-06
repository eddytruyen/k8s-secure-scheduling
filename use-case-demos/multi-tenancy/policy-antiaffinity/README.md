# Multi-tenancy, alternative enforcement — binding-time node isolation

Alternative to `../policy/` for the same use case. `../policy/` pins each
tenant to nodes via a mutated `nodeSelector` (one static node partition per
tenant value, validated by `K8sRequireNodeSelectorsEqualTo`). This subfolder
instead enforces **"different tenants must never share a node"** directly —
the Gatekeeper-side counterpart of KLASTOS's `interClass` AntiAffinity CSC
(`klastos/experiment1/multi-tenancy/harness-antiaffinity/`).

## Why this isn't a mutation (`Assign`)

The first instinct is to inject `spec.affinity.podAntiAffinity` via an
`Assign` mutation, the same mechanism `../policy/mutation.yaml` already uses
for `nodeSelector`. This doesn't work, for two independent reasons:

1. **`Assign`'s `fromMetadata` only ever sees the object being mutated** —
   valid fields are just `namespace`/`name`. It has no access to
   `data.inventory` (the replicated cluster-state cache) and so cannot
   express "exclude whichever OTHER tenant values already exist" — only
   validating constraints get `data.inventory`.
2. **A plain Pod `CREATE` has no `.spec.nodeName` yet.** Co-location is a
   fact about *scheduling*, not the pod spec — there is nothing for a
   mutation (which only ever sees the incoming object at `CREATE`/`UPDATE`)
   to reason about regarding "which node."

## The actual mechanism: reject the `Binding`, not mutate the `Pod`

The pod spec is never touched — no `affinity` block, nothing injected. The
default scheduler picks a candidate node exactly as it normally would (its
own scoring/spreading logic, completely oblivious to tenancy), then submits
a `Binding` object for that node. **That** is the one point where the
proposed node is actually known, and this cluster's
`gatekeeper-validating-webhook-configuration` already intercepts the
`pods/binding` subresource (no extra webhook wiring needed — confirmed live
via `kubectl get validatingwebhookconfigurations -o yaml`).

`template.yaml`'s Rego, on a `Binding` review:
1. Reads the proposed target node (`input.review.object.target.name`).
2. Reads the pod's own tenant (`input.review.namespace` — namespace-derived,
   same signal as `../policy/mutation.yaml`'s own `fromMetadata: namespace`).
3. Queries `data.inventory` for any *other* enumerated tenant namespace with
   a pod already on that node (`other_pod.spec.nodeName == target_node`).
4. Rejects the binding if one is found.

On rejection, the scheduler's own bind-failure retry loop picks a different
node and resubmits — enforcement is a sequence of reject/retry round trips
at the apiserver, not a single Filter-time decision.

`config.yaml` is a required prerequisite: it syncs `Pod` into
`data.inventory` (confirmed absent by default on this cluster — no `Config`
object existed before this was added).

## `tenantNamespaces` is required, not optional

`data.inventory` is scoped by namespace, not by any tenant concept — without
an enumerated `tenantNamespaces` list, every *other* namespace in the
cluster counts as "a different tenant," including `kube-system` (DaemonSets
like kube-proxy run a pod on every single node). Confirmed live: the first
version of this constraint, without the parameter, rejected *every* bind
attempt forever (80/80 test pods stuck `Pending`) because no node is ever
free of a `kube-system` pod. Adding `parameters.tenantNamespaces` and
filtering `other_ns in input.parameters.tenantNamespaces` fixed it. This
list is the same enumerated set `../policy/mutation.yaml` and
`../policy/constraint.yaml` already require via their own
`match.namespaces` — not new tedium this design introduces.

## Live validation (against this cluster, 101 nodes)

Tested with throwaway `tenant-a`/`tenant-b` namespaces (kept separate from
`uc1`-`uc4` to avoid interaction with `../policy/`'s own CRs during
testing; `constraint.yaml` as committed here targets the real `uc1`-`uc4`
namespaces):

- 40 + 40 pods (80 total, plenty of free nodes): zero node overlap, but not
  decisive on its own — natural scheduler spreading could coincidentally
  avoid collision at this low a fill ratio.
- Pushed to 95 + 40 (135 pods on 101 nodes, genuine contention): **zero node
  overlap**, cluster filled to 100/101 nodes, and **20 real logged bind
  rejections** (`FailedScheduling` events citing
  `admission webhook "validation.gatekeeper.sh" denied the request:
  [tenant-node-isolation] binding pod to node <...> would co-locate tenant
  <tenant-a> with tenant <tenant-b>`) as the scheduler was forced to retry
  away from nodes the other tenant already occupied.

## Structural tradeoff vs. KLASTOS's `interClass` AntiAffinity

KLASTOS computes the denied-node set **proactively**, in the CSI, before the
scheduler's Filter plugin ever runs — one pass, no rejected attempts by
construction (confirmed zero rejections in the equivalent KLASTOS-side live
test). This design is inherently **reactive**: the scheduler must actually
attempt and be rejected before trying again, so the number of wasted
bind round-trips grows with contention (here, 20 rejections just at
135-pod scale on a 101-node cluster). Both designs are correct; this is a
genuine architectural overhead difference worth citing, not just an
authoring-convenience one.
