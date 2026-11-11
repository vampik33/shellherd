# Real OpenSSH with PAM, for test/ssh/pam_login_docker_test.dart. The run
# command sets the password of the user "dev" and the methods sshd offers.
FROM ubuntu:24.04
RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends openssh-server \
 && apt-get clean \
 && mkdir -p /run/sshd \
 && ssh-keygen -A \
 && useradd -m -s /bin/sh dev
EXPOSE 22
