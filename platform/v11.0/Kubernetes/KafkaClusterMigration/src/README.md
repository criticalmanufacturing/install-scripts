# Kafka Cluster Migration

This tool can be used to migrate kafka data between two clusters.
It supports topics and consumer groups renaming, which is an essential feature as the topics and consumer groups are prefixed with the system name. It also syncronizes the consumer groups offsets.

This tool is based on Apache MirrorMaker 2.

## Why do we need this tool?
The main need for this tool is the migration between MES v10 and v11.
During v11, infrastructural components (clickhouse, kafka) were removed from the MES stack. They are now external and need to be provided by the client.
During the jump between internal and external kafka, there was the need of renaming some topics and consumer groups, so that there is a convention and we make sure that topics and consumer names won't colide when deploying multiple MES environments to the same external kafka cluster. Therefore, we need to provide a way to move the data between the internal and external kafka, applying the needed renamings, so that the topics and consumer groups have the names according to the excepted by v11 MES stak components.

## Usefull links
- [MirrorMaker 2](https://cwiki.apache.org/confluence/display/KAFKA/KIP-382%3A+MirrorMaker+2.0)
- [Kafka Geo-Replication](https://kafka.apache.org/documentation/#georeplication)
- [Kafka Connect Mirror](https://github.com/a0x8o/kafka/blob/master/connect/mirror/README.md)
- [Microsoft Tutorial](https://learn.microsoft.com/en-us/azure/hdinsight/kafka/apache-kafka-mirror-maker-2)

## Build
- gradle buildDockerImage

## Testing

### Start local clusters
Under KafkaClusterMigration run `docker compose -f ./test/compose.local.yaml up` to start a docker stack with:
- 2 Kafka clusters
- Kafka UI connected to both clusters
- An Init container that will create topics, consumers and publish some messages to the sourceKafka cluster

### Run kafka-connect-mirror tool
- Wait for the kafka clusters to be working (we must be able to see the created topics and messages using kafka-ui)
- Start the `kafka-connect-mirror` by running `docker compose -f ./test/compose.migration.internal.yaml up`
