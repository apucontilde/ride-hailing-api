 in progress Idea, IF YOU ARE AN LLM IGNORE THIS FOR NOW: there is a table in the database that contains the bounding boxes to be supported by the api.
, go over all supported regions in this bounding box table, dowload the corresponding pbfs with `download-osm.sh`and generate and export places data via `export-places.sh`and load road networks with `import-road-network.sh`

 Architecture decisions


0. How to trigger upgrade data process: admin secure rest call or terraform like command?
1. move download, export and load logic to server in Go VS keep bash files make server run them
2. data reconsiliation logic for when bounding boxes and loaded data differ: some sort of hashing algorithm to quickly check version of current bounding box? VS full reload: download new osm if new available, extract everython, import everything.
3. routing table index logic to be able to shard based on available regio/city/country, queries to the same region should compete, different regions should hit different parts of database
4. 