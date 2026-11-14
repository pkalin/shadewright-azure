# A second lab cluster

Design note, 2026-11-14. Tracked in [shadewright#672](https://github.com/pkalin/shadewright/issues/672). It plans
a second, disposable AKS cluster for the verification rows that the first lab cannot run. Nothing here is built:
there are no Terraform changes in this note, and the sizes and prices are inputs to a later task.

## What the second cluster adds

The first lab (`lab/`: one `Standard_B2as_v2` node, Flux, the demo workloads of the fleet repository) runs every
verification row that needs a pull request. Two kinds of row do not fit it:

1. Argo CD as the delivery controller. The operator has one delivery adapter, Flux
   (`internal/providers/delivery/flux`). Argo CD is on the adapter list of the design but is not built, and the
   source mapping reads Flux labels. The second cluster is the place to run an Argo CD adapter once it exists. Until
   then Argo CD gives no row of its own. This note does not design the adapter.
2. A public application whose failures this project did not write. A check that only passes on breakage we
   authored proves little about the diagnosis. The application is the OpenTelemetry Demo (Astronomy Shop),
   decided on 2026-11-14.

## Why the OpenTelemetry demo

Two claims drove the choice. Both were checked against the project's own documentation on 2026-11-14.

It ships documented failure scenarios behind feature flags. The page
[Feature Flags](https://opentelemetry.io/docs/demo/feature-flags/) says the flags are managed by flagd and can be
changed in the web UI or in the raw configuration, and lists the implemented flags. The flag definitions are in
[`src/flagd/demo.flagd.json`](https://github.com/open-telemetry/opentelemetry-demo/blob/main/src/flagd/demo.flagd.json)
of the `open-telemetry/opentelemetry-demo` repository (release 3.1.0, 2026-09-18, was the latest on the check date).
The flags that map to rows of the
[scenario matrix](https://github.com/pkalin/shadewright-fleet/blob/main/scenarios/MATRIX.md):

| Flag | Service | What the documentation says | Matrix row it can feed |
| --- | --- | --- | --- |
| `emailMemoryLeak` | email | "Simulate a memory leak in the `email` service." The variant sets how much each confirmation email body is padded (`1x` to `10000x`, `off`) | Row 2, a leak: the limit is raised and the kill returns later. The chart gives the `email` component a memory limit of 100Mi |
| `adHighCpu` | ad | "Trigger high cpu load in the ad service. If you want to demo cpu throttling, set cpu resource limits" | A CPU symptom. [NEEDS CLARIFICATION: which phase and reason the operator gives for CPU throttling, since the lab's policies cover memory limits and KEDA ceilings only; no row until a follow-up task decides] |
| `cartFailure` | cart | Send the selected percentage of `EmptyCart` calls to a failing cart store (`10%` to `100%`) | A failing service with no resource cause. [NEEDS CLARIFICATION: expected outcome, probably no proposal] |
| `failedReadinessProbe` | cart | Force the readiness probe to fail, simulating a pod "NotReady" condition; Kubernetes deployments only | A failing service. [NEEDS CLARIFICATION: as above] |

Other flags exist (`adFailure`, `paymentFailure`, `kafkaQueueProblems`, `productCatalogFailure` and more). They are
not mapped, because no row of the matrix names a failure of that kind. A flag is a value in the flagd
configuration. Whether an agent may propose changing it is a separate question and is not assumed.

It is delivered as a Helm chart. The page
[Kubernetes deployment](https://opentelemetry.io/docs/demo/kubernetes-deployment/) installs it with
`helm install my-otel-demo open-telemetry/opentelemetry-demo` (chart repository
`https://open-telemetry.github.io/opentelemetry-helm-charts`), and also shows how to render it with
`helm template opentelemetry-demo open-telemetry/opentelemetry-demo --namespace otel-demo > opentelemetry-demo.yaml`.
That gives two rows:

- Installed through a Flux `HelmRelease`, a broken limit is refused by the source mapping with `HelmManaged`
  ([operator ADR-0012](https://shadewright.io/adr/0012-object-to-source-mapping/): Helm values are not supported).
- Rendered into plain YAML, committed, and applied by a Flux `Kustomization`, the same break can reach a pull
  request. The rendered output is large, so it also meets the render check's limits (`TooLarge`; see the matrix).

The first row runs on the first lab too, since Flux installs Helm charts. The second needs a place for the full
application, which the first lab's node does not have (below).

One caution from the same page: the chart does not support upgrades from one version to another, so a session
installs one pinned chart version and is destroyed after it.

## Which rows need AKS, which run on Kind

The Kind cluster has no agent identity, so no pull request is opened there (fleet README, "Kind"). It runs the
symptom and the Incident only.

| Needs | Rows |
| --- | --- |
| Kind is enough | the symptom and the Incident of any scenario; the kill of `oom-leak` was settled there; the admission refusals behind the `delivery-blocked` and `rollout-blocked` rows were checked there by hand |
| The first lab (AKS, agent, model, GitHub App) | every row that opens a pull request on the demo app: rows 1 to 10 of the matrix and the `HelmManaged` refusal |
| The second cluster | the OpenTelemetry Demo rows (the leak in `email`, the rendered chart); any Argo CD row, once an adapter exists |

## Node size

The Demo documents 6 GB of free RAM for the application and Kubernetes 1.24 or later (Kubernetes deployment page,
above). The chart sets memory limits and no requests. Summing the limits of the enabled components in
chart 0.42.6 ([`charts/opentelemetry-demo/values.yaml`](https://github.com/open-telemetry/opentelemetry-helm-charts/blob/opentelemetry-demo-0.42.6/charts/opentelemetry-demo/values.yaml)
of `open-telemetry/opentelemetry-helm-charts` at tag `opentelemetry-demo-0.42.6`, checked 2026-11-14) gives about 6.2 GiB, plus 0.4 GiB for the collector, 0.5 GiB for Grafana and 1.1 GiB for OpenSearch. Jaeger
and Prometheus set none. Argo CD, Flux's controllers and the Shadewright agent come on top. These are limits, not
measured use, so the real figure must be read from a first run before the size is fixed.

The first lab's node (`Standard_B2as_v2`, 2 vCPU, 8 GiB) is too small for that. Proposal: one
`Standard_D4as_v5` node (4 vCPU, 16 GiB, not burstable), the size the README already lists as a fallback.
Two `Standard_D2as_v5` nodes (2 vCPU, 8 GiB each) cost the same and are the alternative if one node proves hard to
get in the region. Sweden Central stays the region ([operator ADR-0016](https://shadewright.io/adr/0016-lab-region-sweden-central/)).

## Price

Azure Retail Prices API (`https://prices.azure.com/api/retail/prices`, public, no login), EUR, Linux pay as you go,
region `swedencentral`, checked 2026-11-14. The meters are those `scripts/lab.sh cost` uses (`make lab-cost`); the
filters name no account, tenant or subscription.

| Resource | Meter | EUR per hour |
| --- | --- | ---: |
| AKS node, `Standard_D4as_v5` Linux | Virtual Machines Dasv5 Series, D4as v5 | 0.1652 |
| OS disk, 32 GB managed | Premium SSD Managed Disks, P4 LRS Disk (5.2132 per month) | 0.0071 |
| Standard Load Balancer, outbound rule | Load Balancer, Standard Included LB Rules and Outbound Rules (Global) | 0.0224 |
| Public IPv4 for outbound | Virtual Network, Standard IPv4 Static Public IP | 0.0045 |
| AKS cluster management, Free tier | none | 0 |
| Flux, Argo CD, the application | none: they run on the node above | 0 |
| **Total** | | **0.1992** |

- Per hour: about 0.20 EUR.
- Per session of 4 hours: about 0.80 EUR.
- Both lab clusters at once, for the same 4 hours: about 1.20 EUR (the first lab costs about 0.10 per hour, README,
  "Cost").

Usage-based extras come on top, as in the first lab: load balancer data processed, internet egress and model tokens.
The 32 GB OS disk is the first lab's setting and is assumed here. Rerun `make lab-cost` with the chosen
`node_vm_size`, `node_count` and `location` before the apply, because prices change.

## Lifetime and the credit cap

The cluster exists for a session and is destroyed after it, as [ADR-0008](https://shadewright.io/adr/0008-disposable-azure-lab/) and the first lab do: apply, run the rows,
destroy, and check that nothing is left (`make lab-check`). It gets its own Terraform root or a switch in `lab/`;
that choice belongs to the Terraform task.

The constraint is the lab's monthly credit. The repository states it as a rule (AGENTS.md, "Cost": the lab must
stay well inside a small monthly credit), and `foundation/variables.tf` sets an alert budget of 50 per month by
default, in the subscription's billing currency. An Azure budget only alerts, it never stops spending. The amount of
the credit itself is not written in this repository, so this note compares against the alert default only. At 0.1992 EUR per hour, a second cluster left up for a month
(730 hours) would cost about 145 EUR, three times that alert level, so the destroy step is not optional. Eight
sessions of 4 hours cost about 6.40 EUR.

## Open points

- The size is a proposal until a first run reads the real memory use of the application with Argo CD and the agent
  on the node.
- The expected outcome for `adHighCpu`, `cartFailure` and `failedReadinessProbe` is open (above).
- The amount of the monthly credit is not in the repository.
- Argo CD gives no row until an adapter exists.
