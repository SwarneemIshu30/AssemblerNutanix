# Microsoft.FailoverCluster Collector Contract

Collects one Windows Server Failover Cluster per `Windows.FailoverCluster` target. The collector connects to ordered `endpoints.seedNodes`, discovers cluster membership, and fans out to nodes. Hyper-V and Storage Spaces Direct datasets are capability-gated. External arrays are represented only through host-visible identifiers.

Contract pack `2.0.12` supports offline pilot validation. Production validation requires live acceptance against S2D/Hyper-V and external-storage clusters.
