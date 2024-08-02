FROM maven:3.9.8-amazoncorretto-8-al2023 as build_stage

WORKDIR /opt
COPY ./src ./src
COPY ./pom.xml ./pom.xml

RUN mvn package

FROM bitnami/kafka:3.7.1 as prod

ENV SOURCE_BOOTSTRAP_SERVERS=kafka1:9092,kafka2:9092,kafka3:9092 \
    TARGET_BOOTSTRAP_SERVERS= \
    OLD_SYSTEM_NAME= \
    NEW_SYSTEM_NAME= \
    SECURITY_PROTOCOL= \
    SSL_TYPE= \
    SSL_KEYSTORE_LOCATION= \
    SSL_KEYSTORE_PASSWORD= \
    SSL_TRUSTSTORE_LOCATION= \
    SSL_TRUSTSTORE_PASSWORD= \
    SASL_MECHANISM= \
    SASL_USERNAME= \
    SASL_PASSWORD= \
    MM2_REPLICATION_FACTOR=3 \
    MIGRATED_TOPICS_REPLICATION_FACTOR=3

WORKDIR /opt/bitnami/kafka/bin

USER ROOT

COPY --chown=$NON_ROOT_USER_PERMS ./config /tmp
COPY --chown=$NON_ROOT_USER_PERMS ./src/scripts /opt/bitnami/kafka/bin/
COPY --chown=$NON_ROOT_USER_PERMS --from=build_stage /opt/target/kafkaclustermigration-1.0-SNAPSHOT.jar /tmp/kafkaclustermigration-1.0-SNAPSHOT.jar

USER $NON_ROOT_USER

RUN chmod 777 /opt/bitnami/kafka/bin/replaceEnvVariables.sh /opt/bitnami/kafka/bin/migrateConsumers.sh /opt/bitnami/kafka/bin/migrateTopicsAndConsumers.sh /tmp

ENV CLASSPATH=$LIBS_PATH"/tmp/kafkaclustermigration-1.0-SNAPSHOT.jar"

CMD /bin/sh -c "./replaceEnvVariables.sh /tmp/kcs.properties && ./replaceEnvVariables.sh /tmp/mm2.properties && ./migrateTopicsAndConsumers.sh"
