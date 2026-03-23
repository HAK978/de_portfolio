#!/bin/bash
# One-time setup for GCE deployment
sudo cp cs2-storage.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable cs2-storage
sudo systemctl start cs2-storage
echo "Service started. Checking status..."
sleep 2
sudo systemctl status cs2-storage --no-pager
