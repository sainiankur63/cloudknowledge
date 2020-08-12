FROM centos:latest
MAINTAINER ankur@gmail.com
RUN yum install -y httpd \
          zip \
          unzip
WORKDIR /var/www/html
RUN echo "First docker container " > /var/www/html
CMD ["/usr/sbin/httpd","-D","FOREGROUND"]
EXPOSE 80
