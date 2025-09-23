FROM debian:13

RUN apt update
RUN apt install -y docker-cli openssh-client findutils

COPY scripts/*.sh /

WORKDIR /github/workspace

ENTRYPOINT [ "/docker-entrypoint.sh" ]
