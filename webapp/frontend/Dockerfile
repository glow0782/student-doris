FROM nginx:latest

COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY index.html dashboard.html /usr/share/nginx/html/
COPY css /usr/share/nginx/html/css
COPY js /usr/share/nginx/html/js
COPY vendor /usr/share/nginx/html/vendor

EXPOSE 80
CMD ["nginx", "-g", "daemon off;"]
