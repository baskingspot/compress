cd /tmp/enc
F="data/icon_16-actions_address_book_new-16x16.raw data/icon_64-actions_address_book_new-64x64.raw data/textures_pk-_pkf_water1-128x128.raw data/test-testcard-256x256.raw data/photo_kodak-kodim01-768x512.raw data/test-dice-800x600.raw"
for lv in 6 7 1; do ./ab.sh /tmp/enc/res-l$lv 10 $lv $F; done
echo ALLDONE
