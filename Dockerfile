# Use Ubuntu 22.04 as the base image
FROM ubuntu:22.04

# Set the proxy
ENV http_proxy=http://proxy.charite.de:8080
ENV https_proxy=http://proxy.charite.de:8080

# Install necessary packages
RUN apt-get update && \
    apt-get install -y lsb-release wget curl gnupg && \
    wget --quiet -O - https://www.postgresql.org/media/keys/ACCC4CF8.asc | gpg --dearmor > /usr/share/keyrings/pgdg-archive-keyring.gpg && \
    echo "deb [signed-by=/usr/share/keyrings/pgdg-archive-keyring.gpg] https://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" > /etc/apt/sources.list.d/pgdg.list && \
    apt-get update && \
    apt-get install -y --install-recommends \
        postgresql-16 \
        libpq-dev \
        nginx \
        libxslt1-dev \
        libxml2-dev \
        libffi-dev \
        libpcre3-dev \
        libyaml-dev \
        libssl-dev \
        zlib1g-dev \
        libbz2-dev \
        libreadline-dev \
        libsqlite3-dev \
        libncurses5-dev \
        libncursesw5-dev \
        xz-utils \
        liblzma-dev \
        uuid-dev \
        build-essential \
        redis-server \
        git \
        libpango1.0-dev \
        libjpeg-turbo8-dev \
        python3-venv \
        python3-pip \
        openssl \
        certbot \
        python3-certbot-nginx \
        sudo

# Ensure the services are started
RUN systemctl enable postgresql.service redis-server.service

# Create directories and set permissions for SSL certificates
RUN mkdir /etc/ssl/indico && \
    chown root:root /etc/ssl/indico/ && \
    chmod 700 /etc/ssl/indico

# Create strong DH params
RUN echo '-----BEGIN DH PARAMETERS-----' > /etc/ssl/indico/ffdhe2048 && \
    echo 'MIIBCAKCAQEA//////////+t+FRYortKmq/cViAnPTzx2LnFg84tNpWp4TZBFGQz' >> /etc/ssl/indico/ffdhe2048 && \
    echo '+8yTnc4kmz75fS/jY2MMddj2gbICrsRhetPfHtXV/WVhJDP1H18GbtCFY2VVPe0a' >> /etc/ssl/indico/ffdhe2048 && \
    echo '87VXE15/V8k1mE8McODmi3fipona8+/och3xWKE2rec1MKzKT0g6eXq8CrGCsyT7' >> /etc/ssl/indico/ffdhe2048 && \
    echo 'YdEIqUuyyOP7uWrat2DX9GgdT0Kj3jlN9K5W7edjcrsZCwenyO4KbXCeAvzhzffi' >> /etc/ssl/indico/ffdhe2048 && \
    echo '7MA0BM0oNC9hkXL+nOmFg/+OTxIy7vKBg8P+OxtMb61zO7X8vC7CIAXFjvGDfRaD' >> /etc/ssl/indico/ffdhe2048 && \
    echo 'ssbzSibBsu/6iGtCOGEoXJf//////////wIBAg==' >> /etc/ssl/indico/ffdhe2048 && \
    echo '-----END DH PARAMETERS-----' >> /etc/ssl/indico/ffdhe2048

# Create a self-signed certificate (for testing purposes)
RUN openssl req -x509 -nodes -newkey rsa:4096 -subj /CN=s-c10-indico01.charite.de -keyout /etc/ssl/indico/indico.key -out /etc/ssl/indico/indico.crt

# Create and setup Indico user
RUN useradd -m indico && \
    su - postgres -c 'createuser indico' && \
    su - postgres -c 'createdb -O indico indico' && \
    su - postgres -c 'psql indico -c "CREATE EXTENSION unaccent; CREATE EXTENSION pg_trgm;"'

# Set up directories for Indico
RUN mkdir -p /opt/indico/web && \
    chown -R indico:www-data /opt/indico

# Copy configuration files
COPY uwsgi.ini /etc/uwsgi-indico.ini
COPY indico-uwsgi.service /etc/systemd/system/indico-uwsgi.service
COPY nginx.conf /etc/nginx/conf.d/indico.conf

# Install pyenv and Python version for Indico
RUN curl -L https://github.com/pyenv/pyenv-installer/raw/master/bin/pyenv-installer | bash && \
    export PATH="/root/.pyenv/bin:$PATH" && \
    eval "$(pyenv init --path)" && \
    eval "$(pyenv init -)" && \
    eval "$(pyenv virtualenv-init -)" && \
    pyenv install 3.12.0 && \
    pyenv global 3.12.0 && \
    python -m venv /opt/indico/.venv

# Install Indico
RUN /opt/indico/.venv/bin/pip install setuptools wheel uwsgi indico

# Add Celery systemd unit file
COPY indico-celery.service /etc/systemd/system/indico-celery.service

# Switch to Indico user and configure Indico
USER indico
WORKDIR /opt/indico
RUN /opt/indico/.venv/bin/indico setup wizard --noinput --hostname=s-c10-indico01.charite.de --db=postgresql+psycopg2://indico:indico@postgres/indico --smtp=your.smtp.server
RUN mkdir -p ~/log/nginx && \
    chmod go-rwx ~/* ~/.[^.] && \
    chmod 710 ~/ ~/archive ~/cache ~/log ~/tmp && \
    chmod 750 ~/web ~/.venv && \
    chmod g+w ~/log/nginx && \
    echo -e "\nSTATIC_FILE_METHOD = ('xaccelredirect', {'/opt/indico': '/.xsf/indico'})" >> ~/etc/indico.conf && \
    /opt/indico/.venv/bin/indico db prepare

# Expose necessary ports
EXPOSE 80 443

# Start the necessary services
CMD ["systemctl", "start", "indico-uwsgi.service", "indico-celery.service", "nginx", "postgresql", "redis-server"]
