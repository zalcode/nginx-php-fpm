FROM php:8.4-fpm-bookworm

LABEL maintainer="Ric Harvey <ric@squarecows.com>"

ENV php_conf=/usr/local/etc/php-fpm.conf
ENV fpm_conf=/usr/local/etc/php-fpm.d/www.conf
ENV php_vars=/usr/local/etc/php/conf.d/docker-vars.ini

# Set DEBIAN_FRONTEND to noninteractive to avoid prompts during package installation
ENV DEBIAN_FRONTEND=noninteractive

RUN --mount=type=cache,id=apt-cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,id=apt-lib,target=/var/lib/apt,sharing=locked\
    apt-get update && apt-get upgrade -y && apt-get install -y \
    curl \
    ca-certificates \
    openssl \
    git \
    libxml2-dev \
    tzdata \
    libicu-dev \
    libzip-dev \
    libpng-dev \
    supervisor \
    libwebp-dev \
    libpq-dev \
    libfreetype6-dev \
    libjpeg-dev \
    libcurl4-openssl-dev \
    libonig-dev \
    default-libmysqlclient-dev \
    nginx \
    # Install fcgi for healthcheck
    libfcgi-bin \
    && apt-get clean && \
    rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

RUN php -m

# Install PHP extensions
RUN docker-php-ext-install \
    bcmath \
    exif \
    gd \
    intl \
    mysqli \
    opcache \
    pcntl \
    pdo_mysql \
    pdo_pgsql \
    sockets \
    zip 


RUN php -m

# install composer
RUN php -r "copy('https://getcomposer.org/installer', 'composer-setup.php');" && \
    php -r "if (hash_file('sha384', 'composer-setup.php') === 'dac665fdc30fdd8ec78b38b9800061b4150413ff2e3b6f88543c636f7cd84f6db9189d43a81e5503cda447da73c7e5b6') { echo 'Installer verified'; } else { echo 'Installer corrupt'; unlink('composer-setup.php'); } echo PHP_EOL;" &&\
    php composer-setup.php &&\
    php -r "unlink('composer-setup.php');" &&\
    mv composer.phar /usr/local/bin/composer


# Cleanup build dependencies
RUN apt-get purge -y --auto-remove gcc make autoconf zlib1g-dev && \
    apt-get autoremove -y && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/* ~/.composer/cache

# We don't need Xdebug in production (improves performance)

ADD conf/supervisord.conf /etc/supervisord.conf

# Copy our nginx config
RUN rm -Rf /etc/nginx/nginx.conf
ADD conf/nginx.conf /etc/nginx/nginx.conf

# nginx site conf
RUN mkdir -p /etc/nginx/sites-available/ && \
    mkdir -p /etc/nginx/sites-enabled/ && \
    mkdir -p /etc/nginx/ssl/ && \
    rm -Rf /var/www/* && \
    mkdir -p /var/www/html/
ADD conf/nginx-site.conf /etc/nginx/sites-available/default.conf
ADD conf/nginx-site-ssl.conf /etc/nginx/sites-available/default-ssl.conf
RUN ln -s /etc/nginx/sites-available/default.conf /etc/nginx/sites-enabled/default.conf

# Optimize PHP for production
# Note: Debian's Nginx default user is www-data. PHP-FPM should match.
RUN echo "cgi.fix_pathinfo=0" > ${php_vars} && \
    echo "upload_max_filesize = 100M" >> ${php_vars} && \
    echo "post_max_size = 100M" >> ${php_vars} && \
    echo "variables_order = \"EGPCS\"" >> ${php_vars} && \
    echo "memory_limit = 256M" >> ${php_vars} && \
    sed -i \
    -e "s/;catch_workers_output\s*=\s*yes/catch_workers_output = yes/g" \
    -e "s/pm.max_children = 5/pm.max_children = 8/g" \
    -e "s/pm.start_servers = 2/pm.start_servers = 4/g" \
    -e "s/pm.min_spare_servers = 1/pm.min_spare_servers = 2/g" \
    -e "s/pm.max_spare_servers = 3/pm.max_spare_servers = 6/g" \
    -e "s/;pm.max_requests = 500/pm.max_requests = 500/g" \
    # Keep user/group as www-data for Debian standard, or change nginx user too
    -e "s/user = www-data/user = www-data/g" \
    -e "s/group = www-data/group = www-data/g" \
    -e "s/;listen.mode = 0660/listen.mode = 0666/g" \
    -e "s/;listen.owner = www-data/listen.owner = www-data/g" \
    -e "s/;listen.group = www-data/listen.group = www-data/g" \
    -e "s/listen = 127.0.0.1:9000/listen = \/var\/run\/php-fpm.sock/g" \
    -e "s/^;clear_env = no$/clear_env = no/" \
    ${fpm_conf}

# Use production PHP configuration in production
RUN cp /usr/local/etc/php/php.ini-production /usr/local/etc/php/php.ini && \
    sed -i \
    -e "s/;opcache.enable=1/opcache.enable=1/g" \
    -e "s/;opcache.memory_consumption=128/opcache.memory_consumption=256/g" \
    -e "s/;opcache.max_accelerated_files=10000/opcache.max_accelerated_files=20000/g" \
    -e "s/;opcache.validate_timestamps=1/opcache.validate_timestamps=0/g" \
    -e "s/;opcache.revalidate_freq=2/opcache.revalidate_freq=0/g" \
    -e "s/;opcache.save_comments=1/opcache.save_comments=1/g" \
    -e "s/;realpath_cache_size=4096k/realpath_cache_size=10240k/g" \
    -e "s/;realpath_cache_ttl=120/realpath_cache_ttl=600/g" \
    /usr/local/etc/php/php.ini

# Add Scripts
ADD scripts/start.sh /start.sh
ADD scripts/pull /usr/bin/pull
ADD scripts/push /usr/bin/push
ADD scripts/letsencrypt-setup /usr/bin/letsencrypt-setup
ADD scripts/letsencrypt-renew /usr/bin/letsencrypt-renew
RUN chmod 755 /usr/bin/pull && chmod 755 /usr/bin/push && chmod 755 /usr/bin/letsencrypt-setup && chmod 755 /usr/bin/letsencrypt-renew && chmod 755 /start.sh

# copy in code
ADD src/ /var/www/html/
ADD errors/ /var/www/errors

# Laravel specific directories
# Adjust user/group to www-data for Debian standard
RUN mkdir -p /var/www/html/storage/app/public \
    /var/www/html/storage/framework/cache \
    /var/www/html/storage/framework/sessions \
    /var/www/html/storage/framework/testing \
    /var/www/html/storage/framework/views \
    /var/www/html/storage/logs && \
    chown -R www-data:www-data /var/www/html && \
    chmod -R 775 /var/www/html/storage

EXPOSE 443 80

WORKDIR "/var/www/html"

CMD ["/start.sh"]
