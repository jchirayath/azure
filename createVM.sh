azure vm create myVM \
-o a879bbefc56a43abb0ce65052aac09f3__RHEL_7_3_Standard_Azure_RHUI-20161104230023 \
-g Admin \
-p Admin123 \
-e 22 \
-t "~/.ssh/id_rsa.pub" \
-z "Small" \
-l "West US"
