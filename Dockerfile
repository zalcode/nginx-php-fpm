FROM php:8.4-fpm-alpine

LABEL maintainer="Ric Harvey <ric@squarecows.com>"

ENV php_conf=/usr/local/etc/php-fpm.conf \
    fpm_conf=/usr/local/etc/php-fpm.d/www.conf \
    php_vars=/usr/local/etc/php/conf.d/docker-vars.ini \
    LUAJIT_LIB=/usr/lib \
    LUAJIT_INC=/usr/include/luajit-2.1 \
    LD_PRELOAD="/usr/lib/preloadable_libiconv.so php"

# Tambahkan repositori dan install paket dasar
RUN echo @testing https://dl-cdn.alpinelinux.org/alpine/edge/testing >> /etc/apk/repositories && \
    apk update

# Install GNU libiconv untuk menyelesaikan issue #166
RUN apk add --no-cache --repository http://dl-3.alpinelinux.org/alpine/edge/community gnu-libiconv

# Install nginx dan modul-modulnya
RUN apk add --no-cache nginx nginx-mod-http-lua nginx-mod-devel-kit

# Install paket umum yang diperlukan di production
RUN apk add --no-cache \
    bash \
    curl \
    libcurl \
    libpq \
    tzdata \
    libpng \
    libzip-dev \
    bzip2-dev \
    icu-dev \
    libpng-dev \
    libjpeg-turbo-dev \
    freetype-dev \
    libxslt-dev \
    supervisor

# Install build dependencies
RUN apk add --no-cache \
    gcc \
    musl-dev \
    linux-headers \
    augeas-dev \
    libmcrypt-dev \
    libffi-dev \
    sqlite-dev \
    imap-dev \
    postgresql-dev \
    lua-resty-core \
    libwebp-dev \
    zlib-dev \
    libxpm-dev \
    autoconf \
    make

# Konfigurasi dan install ekstensi GD
RUN docker-php-ext-configure gd \
    --enable-gd \
    --with-freetype \
    --with-jpeg && \
    docker-php-ext-install gd

# Install ekstensi database
RUN docker-php-ext-install pdo_mysql mysqli pdo_sqlite pgsql pdo_pgsql

# Install ekstensi umum lainnya
RUN docker-php-ext-install opcache
RUN docker-php-ext-install exif
RUN docker-php-ext-install intl
RUN docker-php-ext-install zip
RUN docker-php-ext-install xsl
RUN docker-php-ext-install soap

# Install ekstensi PECL - redis
RUN pecl install -o -f redis && \
    echo "extension=redis.so" > /usr/local/etc/php/conf.d/redis.ini

# Bersihkan cache dan file sementara
RUN docker-php-source delete

# Install composer
RUN php -r "copy('https://getcomposer.org/installer', 'composer-setup.php');" && \
    php composer-setup.php --quiet --install-dir=/usr/bin --filename=composer && \
    rm composer-setup.php

# Buat direktori yang diperlukan
RUN mkdir -p /var/www/app /var/log/supervisor /etc/letsencrypt/webrootauth

# Hapus paket yang hanya diperlukan untuk build
RUN apk del gcc musl-dev linux-headers libffi-dev augeas-dev autoconf make

# Konfigurasi supervisor
COPY conf/supervisord.conf /etc/supervisord.conf

# Konfigurasi nginx
RUN rm -Rf /etc/nginx/nginx.conf && \
    mkdir -p /etc/nginx/sites-available/ /etc/nginx/sites-enabled/ /etc/nginx/ssl/ && \
    rm -Rf /var/www/* && \
    mkdir -p /var/www/html/

COPY conf/nginx.conf /etc/nginx/nginx.conf
COPY conf/nginx-site.conf /etc/nginx/sites-available/default.conf
COPY conf/nginx-site-ssl.conf /etc/nginx/sites-available/default-ssl.conf
RUN ln -s /etc/nginx/sites-available/default.conf /etc/nginx/sites-enabled/default.conf

# Konfigurasi PHP-FPM untuk produksi
RUN echo "cgi.fix_pathinfo=0" > ${php_vars} && \
    echo "upload_max_filesize = 100M" >> ${php_vars} && \
    echo "post_max_size = 100M" >> ${php_vars} && \
    echo "variables_order = \"EGPCS\"" >> ${php_vars} && \
    echo "memory_limit = 128M" >> ${php_vars} && \
    sed -i \
    -e "s/;catch_workers_output\s*=\s*yes/catch_workers_output = yes/g" \
    -e "s/pm.max_children = 5/pm.max_children = 8/g" \
    -e "s/pm.start_servers = 2/pm.start_servers = 3/g" \
    -e "s/pm.min_spare_servers = 1/pm.min_spare_servers = 2/g" \
    -e "s/pm.max_spare_servers = 3/pm.max_spare_servers = 4/g" \
    -e "s/;pm.max_requests = 500/pm.max_requests = 500/g" \
    -e "s/user = www-data/user = nginx/g" \
    -e "s/group = www-data/group = nginx/g" \
    -e "s/;listen.mode = 0660/listen.mode = 0666/g" \
    -e "s/;listen.owner = www-data/listen.owner = nginx/g" \
    -e "s/;listen.group = www-data/listen.group = nginx/g" \
    -e "s/listen = 127.0.0.1:9000/listen = \/var\/run\/php-fpm.sock/g" \
    -e "s/^;clear_env = no$/clear_env = no/" \
    ${fpm_conf} && \
    cp /usr/local/etc/php/php.ini-production /usr/local/etc/php/php.ini && \
    sed -i \
    -e "s/;opcache.enable=1/opcache.enable=1/g" \
    -e "s/;opcache.memory_consumption=128/opcache.memory_consumption=256/g" \
    -e "s/;opcache.interned_strings_buffer=8/opcache.interned_strings_buffer=16/g" \
    -e "s/;opcache.max_accelerated_files=10000/opcache.max_accelerated_files=10000/g" \
    -e "s/;opcache.validate_timestamps=1/opcache.validate_timestamps=0/g" \
    -e "s/;opcache.save_comments=1/opcache.save_comments=1/g" \
    -e "s/;opcache.fast_shutdown=0/opcache.fast_shutdown=1/g" \
    /usr/local/etc/php/php.ini

# Tambahkan script
COPY scripts/start.sh /start.sh
COPY scripts/pull /usr/bin/pull
COPY scripts/push /usr/bin/push
COPY scripts/letsencrypt-setup /usr/bin/letsencrypt-setup
COPY scripts/letsencrypt-renew /usr/bin/letsencrypt-renew
RUN chmod 755 /usr/bin/pull /usr/bin/push /usr/bin/letsencrypt-setup /usr/bin/letsencrypt-renew /start.sh

# Salin kode aplikasi
COPY src/ /var/www/html/
COPY errors/ /var/www/errors

EXPOSE 443 80

WORKDIR "/var/www/html"
CMD ["/start.sh"]
