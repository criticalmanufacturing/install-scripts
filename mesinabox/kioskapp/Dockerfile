# Install the application dependencies in a full UBI Node docker image
FROM registry.access.redhat.com/ubi9/nodejs-20:latest as builder

# Configure workdir
USER root
WORKDIR /opt/app-root/src

# Copy package and package-lock
COPY package*.json ./

# Install app dependencies
RUN npm ci --only=production

# Use a minimal nodejs image for the final target
FROM registry.access.redhat.com/ubi9/nodejs-20-minimal:latest 

USER root
EXPOSE 8081
WORKDIR /opt/app-root/src

# Required Red Hat certification labels
LABEL name="cmos" \
      maintainer="contact@criticalmanufacturing.com" \
      vendor="CRITICAL MANUFACTURING, S.A." \
      summary="Critical Manufacuring OS" \
      description="An application to setup the system for App Platform and Apps"

# Node production and web server port
ENV NODE_ENV=production \
    PORT=8081

# Add licenses (required for Red Hat certification)
ADD  https://dev.criticalmanufacturing.io/repository/http/license.txt /licenses/license.txt

# Install ca-certificates, powershell and portal-sdk
RUN curl -sSL -O https://packages.microsoft.com/config/rhel/9/packages-microsoft-prod.rpm && \
    rpm -i packages-microsoft-prod.rpm && \
    microdnf update && \
    microdnf --nodocs install -y ca-certificates powershell && \
    rm packages-microsoft-prod.rpm && \
    microdnf clean all && \
    rm -rf /var/cache/dnf

# Copy necessary scripts
COPY ./scriptAfterEnrollment/afterEnrollment.ps1 /opt/app-root
COPY ./scriptAfterEnrollment/deployAgent.ps1 /opt/app-root

# Install app dependencies from node modules
COPY --from=builder /opt/app-root/src/node_modules /opt/app-root/src/node_modules

# Copy app content
COPY . /opt/app-root/src

CMD ["npm", "start"]