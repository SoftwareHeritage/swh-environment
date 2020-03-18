FROM jboss/keycloak

USER root
# install python3 and python-keycloak, this is needed to execute a
# custom config script after keycloak server is up
RUN microdnf install -y python3 && microdnf clean all
RUN pip3 install python-keycloak
# install wait-for-it script
RUN curl https://raw.githubusercontent.com/vishnubob/wait-for-it/master/wait-for-it.sh > /wait-for-it.sh
RUN chmod +x /wait-for-it.sh

USER jboss
# Modify some config files for keycloak to work properly behind a reverse proxy
# https://stackoverflow.com/questions/44624844/configure-reverse-proxy-for-keycloak-docker-with-custom-base-url
RUN sed -i -e 's/<web-context>auth<\/web-context>/<web-context>keycloak\/auth<\/web-context>/' $JBOSS_HOME/standalone/configuration/standalone.xml
RUN sed -i -e 's/<web-context>auth<\/web-context>/<web-context>keycloak\/auth<\/web-context>/' $JBOSS_HOME/standalone/configuration/standalone-ha.xml
RUN sed -i -e 's/name="\/"/name="\/keycloak\/"/' $JBOSS_HOME/standalone/configuration/standalone.xml
RUN sed -i -e 's/name="\/"/name="\/keycloak\/"/' $JBOSS_HOME/standalone/configuration/standalone-ha.xml
RUN sed -i -e 's/\/auth/\/keycloak\/auth"/' $JBOSS_HOME/welcome-content/index.html
