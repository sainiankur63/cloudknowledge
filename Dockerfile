FROM centos:latest
MAINTAINER ankur@gmail.com
RUN yum install -y httpd \
          zip \
          unzip
ADD  https://www.free-css.com/assets/files/free-css-templates/download/page257/evolo.zip  /var/www/html/
WORKDIR /var/www/html
RUN unzip evolo.zip
RUN cp -rvf documentation/*
RUN rm -rf documentation evolo.zip
CMD ["/usr/sbin/httpd","-D","FOREGROUND"]
EXPOSE 80
