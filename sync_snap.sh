#!/bin/bash
# Демон скрипта syncsnap
# Логи выполнения скрипта /var/log/syncsnap.log

cd $(dirname $0)
working_dir=$(pwd)
config="${working_dir}/hosts.conf"
mkdir -p ${working_dir}/.tmp
today=$(echo `date +%F`)

while true; do
for target_host in $(cat ${config}); do
    echo "$(date) Start sync on ${target_host}" >> /var/log/syncsnap.log
    # Получаем список запущенных контейнеров на target_host
    containers_ids=$(ssh ${target_host} "vzlist -H -o ctid 2> /dev/null" | awk '{print $1}')
    if [[ $? -ne 0 ]]; then
        echo "$(date) Can't get containers list from ${target_host}" >> /var/log/syncsnap.log
        exit 1
    fi

    for container_id in ${containers_ids}; do
    # Забираем конфиги контейнеров с target_host
        rsync -aqL ${target_host}:/etc/vz/conf/${container_id}.conf /etc/vz/conf
        echo "$(date) Sync container ${container_id} on ${target_host}" >> /var/log/syncsnap.log
        mkdir -p /vz/private/${container_id}/root.hdd

    # Проверяем не запущен ли контейнер
        is_container_alive=$(vzlist -H -o ctid 2> /dev/null | grep ${container_id} | wc -l)
        if [[ $is_container_alive -gt 0 ]]; then
            echo "$(date) Stop container ${container_id} before sync" >> /var/log/syncsnap.log
            exit 1
        fi

    echo "$(date) Rsync configs container" >> /var/log/syncsnap.log
    rsync -aq  ${target_host}:/vz/private/${container_id}/Snapshots.xml /vz/private/${container_id}/Snapshots.xml
    rsync -aq ${target_host}:/vz/private/${container_id}/root.hdd/DiskDescriptor.xml /vz/private/${container_id}/root.hdd/DiskDescriptor.xml
    rsync -aq ${target_host}:/vz/private/${container_id}/root.hdd/DiskDescriptor.xml /vz/private/${container_id}/root.hdd/DiskDescriptor.xml.lck
        if [[ $? -ne 0 ]]; then
            echo "$(date) Can't get files from ${target_host} for container id ${container_id}" >> /var/log/syncsnap.log
            exit 1
        fi

    # Создается файл для проверки рестора на резервной ноде
    ssh ${target_host} "vzctl exec ${container_id} mkdir -p /root/timemark 2>/dev/null"
    ssh ${target_host} "vzctl exec ${container_id} find /root/timemark/ -maxdepth 1 -type f -name "????-??-??" -delete 2>/dev/null"
    echo "$(date) Create time marker in ${container_id} /root/timemark/${today}" >> /var/log/syncsnap.log
    ssh ${target_host} "vzctl exec ${container_id} touch /root/timemark/${today} 2> /dev/null"
        if [[ $? -ne 0 ]]; then
                echo "$(date) Can't create time mark in ${target_host} for container id ${container_id}" >> /var/log/syncsnap.log
                exit 1
        fi

    # Делаем snapshot
        ssh ${target_host} "vzctl snapshot ${container_id} --skip-suspend 2> /dev/null" > ${working_dir}/.tmp/${target_host}_${container_id}
        if [[ $? -ne 0 ]]; then
            echo "$(date) Can't create snapshot on ${target_host} for container id ${container_id}" >> /var/log/syncsnap.log
            exit 1
        fi

        last_snapshot_image_path=$(grep -E "Creating snapshot.+dev=.+img=" ${working_dir}/.tmp/${target_host}_${container_id} | sed 's/.*img=\(.*\)/\1/g')
        last_snapshot_image_name=$(basename ${last_snapshot_image_path})

    # Получаем актуальный root.hdd
        is_hdd_actual=0

        if [[ -f /vz/private/${container_id}/root.hdd/root.hdd ]]; then

    # Сверяем md5 root.hdd
            origin_hdd_sum=$(ssh ${target_host} "md5sum /vz/private/${container_id}/root.hdd/root.hdd" | awk '{print $1}')
            backup_hdd_sum=$(md5sum /vz/private/${container_id}/root.hdd/root.hdd | awk '{print $1}')

            echo "$(date) Origin hdd: ${origin_hdd_sum}. Backup hdd: ${backup_hdd_sum}" >> /var/log/syncsnap.log
            if [[ "${origin_hdd_sum}" == "${backup_hdd_sum}" ]]; then
                is_hdd_actual=1
            fi
        fi

    # Если root.hdd не актуальный, актуализируем его
        if [[ $is_hdd_actual -eq 0 ]]; then
            echo "$(date) Update root.hdd image" >> /var/log/syncsnap.log
            rsync -aq ${target_host}:/vz/private/${container_id}/root.hdd/root.hdd /vz/private/${container_id}/root.hdd/root.hdd
        fi

    # Проверяем есть ли для нас snapshot
        ssh ${target_host} "vzctl snapshot-list ${container_id} -H -o uuid,date 2> /dev/null" > ${working_dir}/.tmp/${target_host}_${container_id}_snapshots_list
        if [[ $? -ne 0 ]]; then
            echo "$(date) Can't get snapshot list on ${target_host} for container id ${container_id}" >> /var/log/syncsnap.log
            exit 1
        fi

    # Если snapshot меньше 2, то пропускаем синхронизацию
        snapshots_count=$(cat ${working_dir}/.tmp/${target_host}_${container_id}_snapshots_list | wc -l)
        if [[ ${snapshots_count} -lt 2 ]]; then
            echo "$(date) Found ${snapshots_count} snapshots for ${container_id} on host ${target_host}, skip sync" >> /var/log/syncsnap.log
            continue
        fi

    # Забираем файлы, за исключением root.hdd и активного snapshot
        rsync -aq \
            --exclude root.hdd/root.hdd \
            --exclude root.hdd/${last_snapshot_image_name} \
            --exclude Snapshots.xml \
            --exclude root.hdd/DiskDescriptor.xml \
            --exclude root.hdd/DiskDescriptor.xml.lck \
            ${target_host}:/vz/private/${container_id}/ /vz/private/${container_id}

        if [[ $? -ne 0 ]]; then
            echo "$(date) Can't get files from ${target_host} for container id ${container_id}" >> /var/log/syncsnap.log
            exit 1
        fi

    # Выполняем merge snapshot
        snapshots_ids=$(cat ${working_dir}/.tmp/${target_host}_${container_id}_snapshots_list | head -n -2 | awk '{print $1}' | sed 's/{\(.*\)}/\1/g')
        for snapshot_id in ${snapshots_ids}; do
            vzctl snapshot-delete ${container_id} --id ${snapshot_id} 2> /dev/null  1> ${working_dir}/.tmp/${target_host}_${container_id}.log
            if [[ $? -ne 0 ]]; then
                echo "$(date) Can't merge local snapshot ${snapshot_id} for ${container_id}" >> /var/log/syncsnap.log
                exit 1
            fi

            ssh ${target_host} vzctl snapshot-delete ${container_id} --id ${snapshot_id} 2> /dev/null 1>> ${working_dir}/.tmp/${target_host}_${container_id}.log
            if [[ $? -ne 0 ]]; then
                echo "$(date) Can't merge remote snapshot ${snapshot_id} for ${container_id} on ${target_host}" >> /var/log/syncsnap.log
                exit 1
            fi
        done

    # Получаем последний не активный snapshot и восстанавливаемся на него
        target_snapshot_id=$(cat ${working_dir}/.tmp/${target_host}_${container_id}_snapshots_list | tail -n 2 | head -n 1 | awk '{print $1}' | sed 's/{\(.*\)}/\1/g')
        vzctl snapshot-switch ${container_id} --id ${target_snapshot_id} 2> /dev/null  1>> ${working_dir}/.tmp/${target_host}_${container_id}.log
        if [[ $? -ne 0 ]]; then
            echo "$(date) Can't switch to snapshot id ${snapshot_id} on container id ${container_id}" >> /var/log/syncsnap.log
            exit 1
        fi

    # Удаляю все кроме новой дельты
        path_delta=$(grep "Creating delta" ${working_dir}/.tmp/${target_host}_${container_id}.log  | awk '{print $3}')
        name_delta=$(basename ${path_delta})
        find /vz/private/${container_id}/root.hdd/  -maxdepth 1 -type f -name 'root.hdd.{*' -not -name ${name_delta} -delete

    # Сверяем md5 root.hdd
        origin_hdd_sum=$(ssh ${target_host} "md5sum /vz/private/${container_id}/root.hdd/root.hdd" | awk '{print $1}')
        backup_hdd_sum=$(md5sum /vz/private/${container_id}/root.hdd/root.hdd | awk '{print $1}')

        echo "$(date) Origin hdd: ${origin_hdd_sum}. Backup hdd: ${backup_hdd_sum}" >> /var/log/syncsnap.log
        echo "$(date) Finish." >> /var/log/syncsnap.log
        echo >> /var/log/syncsnap.log
        echo >> /var/log/syncsnap.log
    done
done

    # Проверка восстановления
echo "$(date) Get containers list" > /tmp/debug_restore.log; echo
containers_ids=$(vzlist -a -H -o ctid 2> /dev/null | awk '{print $1}')
    if [[ $? -ne 0 ]]; then
        echo "$(date) Can't get containers list from"
        exit 1
    fi

sum_ids=$(vzlist -a -H -o ctid 2> /dev/null | wc -l)
echo "All backup CT ${sum_ids}" > /tmp/check_restore.log
echo "Mounts errors - 0" >> /tmp/check_restore.log
echo "Lost time mark in CT - 0" >> /tmp/check_restore.log; echo


for container_id in ${containers_ids}; do
    ct_name=$(vzlist ${container_id} 2> /dev/null | tail -n 1 | awk '{print $5}')
    echo "$(date) Mount ploop CTID ${container_id} ${ct_name} in /mnt/" >> /tmp/debug_restore.log; echo
    ploop mount -m /mnt/ /vz/private/${container_id}/root.hdd/DiskDescriptor.xml 1>> /tmp/debug_restore.log 2>> /tmp/debug_restore.log
    if [[ $? -ne 0 ]]; then
        echo "$(date) Can't mount  ploop CTID ${container_id} ${ct_name} in /mnt/" >> /tmp/debug_restore.log
        echo "$(date) Ploop CTID ${container_id} ${ct_name} failed to mount, see /tmp/debug_restore.log" >> /tmp/check_restore.log; echo

    # Подсчет потерь меток
        current_mount_fail=$(sed -n 2p /tmp/check_restore.log | awk '{print $4}')
        sum_mount_fail=$((${current_mount_fail}+1))
        sum_mount_fail=$(echo "Mounts errors - ${sum_mount_fail}")
        sed -i "2s/.*/${sum_mount_fail}/" /tmp/check_restore.log

    continue
    fi

    if [ -f /mnt/root/timemark/${today} ]; then
        echo "$(date) CTID ${container_id} ${ct_name} time mark ${today} exist and match" >> /tmp/debug_restore.log
        ploop umount /vz/private/${container_id}/root.hdd/DiskDescriptor.xml 1>> /tmp/debug_restore.log 2>> /tmp/debug_restore.log
        echo "$(date) Ploop CTID ${container_id} ${ct_name} umount" >> /tmp/debug_restore.log; echo

    else

   # Подсчет потерь меток
        current_fail=$(sed -n 3p /tmp/check_restore.log | awk '{print $7}')
        sum_fail=$((${current_fail}+1))
        sum_fail=$(echo "Lost time mark in CT - ${sum_fail}")
        sed -i "3s/.*/${sum_fail}/" /tmp/check_restore.log

        echo "$(date) CTID ${container_id} ${ct_name} You must check restore backup" >> /tmp/check_restore.log
        echo "$(date) Time mark ${today} in CTID ${container_id} ${ct_name} doesn't exist"  >> /tmp/check_restore.log
        echo "$(date) Last mark in CTID ${container_id} ${ct_name} $(ls /mnt/root/timemark/ 2>> /tmp/debug_restore.log)"  1>> /tmp/check_restore.log; echo
        ploop umount /vz/private/${container_id}/root.hdd/DiskDescriptor.xml 1>> /tmp/debug_restore.log 2>> /tmp/debug_restore.log
        echo "$(date) Ploop CTID ${container_id} ${ct_name} umount" >> /tmp/debug_restore.log; echo
    fi
done
done
