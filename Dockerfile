FROM centos:latest
MAINTAINER ankur@gmail.com
RUN yum install -y httpd \
          zip \
          unzip
ADD  https://www.free-css.com/assets/files/free-css-templates/download/page257/chershoee.zip  /var/www/html/
WORKDIR /var/www/html
RUN unzip chershoee.zip
RUN cp -rvf chershoee/* .
CMD ["/usr/sbin/httpd","-D","FOREGROUND"]
EXPOSE 80
