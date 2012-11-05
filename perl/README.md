### HOW TO RUN ###

## BUILD memcached & openresty ##

    $ export CWD=`pwd`
    $ wget http://memcached.googlecode.com/files/memcached-1.4.15.tar.gz
    $ tar zxf memcached-1.4.15.tar.gz
    $ cd memcached-1.4.15
    $ ./configure --prefix=$CWD/memcached
    $ make
    $ make install
    $ cd ..
    $
    $ wget http://agentzh.org/misc/nginx/ngx_openresty-1.2.3.8.tar.gz
    $ tar zxf ngx_openresty-1.2.3.8.tar.gz
    $ cd ngx_openresty-1.2.3.8
    $ export PATH=/sbin:$PATH
    $ ./configure --with-luajit --prefix=$CWD/ngx --with-http_gzip_static_module
    $ make
    $ make install
    $ cd ..
    $ mv ngx/nginx/conf/nginx.conf ngx/nginx/conf/nginx.conf.orig
    $ ln -s ../../../nginx.conf ngx/nginx/conf/nginx.conf


## INSTALL CPAN MODULE ##

    $ curl -k -L http://cpanmin.us/ > ./cpanm
    $ chmod +x ./cpanm
    $ ./cpanm -n --installdeps .

## RUN ##

    $ perl start.pl

plackupが5000、nginxが8080で起動します