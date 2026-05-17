last_version="v0.0.0"

while read -r item; do
    tag=$(echo "$item" | jq -r '.tag_name')

    compare_result=$(bash ./compare_versions.sh $last_version $tag)
    if (( compare_result==2 )) then
        last_version=$tag
    fi
done < <( cat /tmp/releases | jq -c '.[] | select(.tag_name != "dict-nightly")')

echo $last_version
