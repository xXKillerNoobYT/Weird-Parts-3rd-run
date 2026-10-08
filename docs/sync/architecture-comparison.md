# Five architecture designs for offline mixed-version sync

Date: 2026-10-08. [Issue #45](https://github.com/xXKillerNoobYT/Weird-Parts-3rd-run/issues/45) extends the existing [issue #33](https://github.com/xXKillerNoobYT/Weird-Parts-3rd-run/issues/33) plan. Three independent Windows architects and two independent Mac architects produced separate frozen proposals before integration. No library or implementation is selected. All proposed engine behavior and performance remain **UNPROVEN**.

The recommended experiment combines a typed command/entity registry, immutable original operation bytes, bounded authorized carriage, and supported local projections. It draws on A, B and D. It keeps C's finer text merge and E's broader adapter matrix conditional on an actual need and a passing experiment. First complete the exact-candidate native gate in issue #39.

## Five actual designs and their authors' ratings

Every author used security 25%, correctness 25%, compatibility 20%, simplicity 15%, Flutter/platform fit 10%, and bounded resource cost 5%. Each criterion is 1 to 5. Weighted result is `sum(score * weight) / 100`.

The table reproduces each author's judgment of their own design. These are neither benchmarks nor controlled peer rankings. Shared weights do not make differently interpreted baselines identical. No average is used to select an implementation.

| Design and author host | Distinctive choice | Security | Correctness | Compatibility | Simplicity | Flutter fit | Resource cost | Author score /5 |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| A, Windows | Typed entity/operation registry, explicit capabilities and constrained unknown-byte carriage. | 4 | 5 | 4 | 3 | 4 | 4 | 4.10 |
| B, Windows | Signed immutable authored operations are primary; typed views and separate receipt stages derive from history. | 4 | 5 | 5 | 2 | 4 | 3 | 4.10 |
| C, Windows | Typed authority and operations with an optional constrained CRDT Notebook kernel. | 4 | 4 | 4 | 2 | 2 | 2 | 3.40 |
| D, Mac | Lossless envelopes, one extensible reducer registry, declared extension and dependency rules. | 4 | 4 | 4 | 3 | 4 | 3 | 3.80 |
| E, Mac | Opaque custody plus contract-pinned semantic-generation adapters and reviewed migration provenance. | 4 | 4 | 4 | 2 | 4 | 3 | 3.65 |

All 17 rating rows across the five full proposals were arithmetically checked. Some rows evaluate generic alternatives rather than another architect's actual design. D's strictly typed baseline excludes unsupported transit, whereas actual A includes constrained carriage. B's rejected generic CRDT merges all state, whereas actual C excludes authority and disputed meaning. E's rows labeled A and B are generic alternatives. They are not peer reviews of delivered architects A and B.

## Tradeoffs and useful preparation

| Design | Useful contribution | Main cost or reason to defer |
| --- | --- | --- |
| A | Registry makes entity semantics, permissions, migration and capabilities explicit. Ordinary later modules can use conformance fixtures. | A registry alone is not durable replication. Keep projections and original bytes consistent and show deferred capability state honestly. |
| B | Durable authored history naturally preserves original users/devices through rotating runners and deduplicates retries. | Signing, authorization, causal dependencies, multiple receipt stages and bounded retention create substantial policy and storage work. |
| C | Stable text/block identities may reduce later collaborative editor work. | Structural convergence does not decide construction meaning. A second document/history model must share the local transaction boundary and justify its Flutter integration cost. |
| D | Narrow supported-field patches preserve unseen data. One registry can advertise installed semantic capabilities. | Unknown data and dependency groups require finite quotas, deferred views, retention and explicit completeness rules. Generic descriptors cannot validate unknown required invariants. |
| E | Reviewed adapters make breaking semantic changes and transformation provenance explicit. | Adapter combinations and supported-generation matrices increase maintenance. Never execute an adapter supplied by a peer. |

A, B and D substantially overlap. E can add release governance inside that shared structure. C can later be one registered content merge handler. These are design dimensions, not five packages that must compete for exclusive ownership of the database.

## Hard exclusions before scoring

The proposed design must reject an unsupported mandatory authentication or envelope rule before protected disclosure or accepted custody. Unknown business semantics may remain opaque only under an understood, authorized and bounded carrier contract. Custody must never imply apply, shop acceptance, physical fulfillment or human acknowledgment.

Disqualify any candidate that silently loses unknown fields, clones device credentials, rolls back known revocation, hides conflicting intent, resurrects deleted records through stale edits or restore, repeats effects on retry, or accepts unbounded hostile input. A good weighted score cannot cancel one such failure. All five designs specify mitigations; none has proved them in a running engine.

User/PIN portability needs a precise boundary. Users must sign in offline on any authorized company device after protected provisioning. Raw PINs and device private keys must not enter ordinary business envelopes. Protected, versioned company-user authentication provisioning remains a required separate security design under issue #38. Earlier broad exclusions of every verifier or recovery credential are narrowed here so they do not contradict cross-device sign-in. Device credentials and active sessions remain local; backup cannot enroll a device or roll back known revocation.

Same-installation business recovery can preserve its verified local installation identity. A replacement installation needs authorized enrollment. Loss of operation-counter continuity needs a fresh authorized operation generation. Neither case may activate an archived sender key or reuse an ID for different bytes.

Warehouse pickup examples illustrate independent action accounting. Actual warehouse workflows remain later scope, not new F1 or issue #39 blockers. Notebook conflict questions belong to the original editors on any authorized device; attributed alternatives remain visible until an authorized resolution, with manager escalation under declared policy. The common core must retain the necessary attribution and causal history now without building Notebook UI.

## What current code proves

The inspected feature source is `95a06a96994ec03014a37075ce4406f183e3c12e`, not assumed merged main. Its [Drift table list and schema](https://github.com/xXKillerNoobYT/Weird-Parts-3rd-run/blob/95a06a96994ec03014a37075ce4406f183e3c12e/app/lib/data/app_database.dart#L20) are fixed and versioned. [Shared row metadata](https://github.com/xXKillerNoobYT/Weird-Parts-3rd-run/blob/95a06a96994ec03014a37075ce4406f183e3c12e/app/lib/data/tables/taxonomy.dart#L4) includes IDs, origin device, row revision and tombstone, but no field-level causal operation history or portable human authorization.

[Job-line updates](https://github.com/xXKillerNoobYT/Weird-Parts-3rd-run/blob/95a06a96994ec03014a37075ce4406f183e3c12e/app/lib/data/daos/jobs_dao.dart#L96) replace scalar fields. [Nearby receive](https://github.com/xXKillerNoobYT/Weird-Parts-3rd-run/blob/95a06a96994ec03014a37075ce4406f183e3c12e/app/lib/features/nearby/nearby_controller.dart#L889) applies a whole packed shop. [Schema validation](https://github.com/xXKillerNoobYT/Weird-Parts-3rd-run/blob/95a06a96994ec03014a37075ce4406f183e3c12e/app/lib/features/backup/backup_store.dart#L38) rejects unsupported database schema. [Staged profile restoration](https://github.com/xXKillerNoobYT/Weird-Parts-3rd-run/blob/95a06a96994ec03014a37075ce4406f183e3c12e/app/lib/features/backup/backup_store.dart#L521) preserves the explicitly supplied recipient profile; the low-level call must receive that local profile. These are useful existing boundaries, not an implemented semantic merge, company enrollment or unknown-data relay.

## Research limits and next experiment

Automerge retains concurrent property alternatives, but ordinary property reads choose a deterministic value and a later assignment clears the current conflict view. Permanent attributed dispute history and semantic resolution therefore need an explicit application contract even with that library. This does not select Automerge or prove a Dart binding. [Official conflict documentation](https://automerge.org/docs/reference/documents/conflicts/).

Protocol Buffers preserves unknown fields in binary messages but documents loss through JSON serialization and field-by-field reconstruction. Byte-preserving carriage and narrow edits need end-to-end tests regardless of the eventual format. [Official unknown-field documentation](https://protobuf.dev/programming-guides/proto3/#unknown-fields).

The smallest comparison after F0 uses three disposable stores, a typed catalog/job operation, independently edited fields, one unknown optional payload, unknown required authentication, an unauthorized device, a tombstone and an interrupted receive. Require exact byte preservation, separate stored/applied receipts, complete identity/reference equality, visible conflicts and exactly-once effects after restart/retry. Add a synthetic later entity through the registry without changing transport code. No real later module is required for that extension check.

Only after correctness compare resource use and native fit. Record exact versions, datasets, operation history, bytes, memory/disk, processing time, resumption and limits. Native radio, key-store, editor, mobile, Bluetooth and on-device AI support each remain untested until their scoped platform checks run. A faster or more compatible result cannot excuse failed authorization or data-loss checks.

## Frozen proposal provenance

Full independent proposals remain in approved private evidence on the authors' hosts and admitted byte-exact coordinator copies. Hashes below identify the reviewed design inputs, not production binaries or passing engine tests. Shared documentation omits private filesystem paths and credential values.

| Input | SHA-256 |
| --- | --- |
| A typed registry | `e6e0df0f19ad06442de98e62923a1f1cde89c25f246320b6aa9f38d9e7f15b34` |
| B signed operations | `95606faa3e9de8b56ec6c55f915d144ed2b09f3dfe56bb379b6309cff6634a15` |
| C constrained CRDT | `b68322ecb97ee20f60f84556614d32d554f3d3f17851e56a7cfe0680ef01ac12` |
| D extensible entity registry | `8e52d6f52228c004d20f9404fe7f102972e12bfbd146f2416952e752ded2bb31` |
| E contract-pinned adapters | `e6484a07e6dfef154e3580801791a7416d525b4b17a15d196bbe90378e9951d8` |

The integration critique found the credential-portability, stage-label, rating-baseline, conflict-routing and recovery-identity gaps above. They are incorporated into the [common plan](foundation-plan.md). No original proposal is rewritten to hide disagreement. The documentation increment still requires its independent final review; that review is distinct from current native acceptance and future engine validation.
