#!/bin/bash

echo "🔍 EFI bölümünün UUID'sini girin (örn: 089A-2447):"
read -rp "UUID: " EFI_UUID

# Geçerli UUID'yi sistemde kontrol et
MATCHING_PART=$(blkid | grep "$EFI_UUID" | grep vfat | awk -F: '{print $1}')

if [[ -z "$MATCHING_PART" ]]; then
    echo "❌ Geçersiz UUID: '$EFI_UUID'. Bu UUID'ye sahip bir EFI (vfat) bölümü bulunamadı."
    exit 1
fi

echo "✅ EFI bölümü bulundu: $MATCHING_PART"

# GRUB girdisini yaz
cat <<EOF | sudo tee /etc/grub.d/40_custom > /dev/null
#!/bin/sh
exec tail -n +3 \$0
# Custom Windows Boot Manager entry
menuentry "Windows Boot Manager (Manual)" {
    insmod part_gpt
    insmod fat
    search --no-floppy --fs-uuid --set=root $EFI_UUID
    chainloader /EFI/Microsoft/Boot/bootmgfw.efi
}
EOF

# Çalıştırma izni ver
sudo chmod +x /etc/grub.d/40_custom

# GRUB'u güncelle
echo "🔄 GRUB yapılandırması güncelleniyor..."
sudo update-grub

echo -e "\n✅ Windows Boot Manager başarıyla GRUB menüsüne eklendi!"
echo "🖥️ Şimdi sistemi yeniden başlatıp GRUB menüsünden Windows'u seçebilirsin."
