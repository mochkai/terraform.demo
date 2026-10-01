import json
import logging
from urllib.parse import unquote_plus


logger = logging.getLogger()
logger.setLevel(logging.INFO)


def lambda_handler(event, context):
    for message in event.get("Records", []):
        payload = json.loads(message["body"])
        for record in payload.get("Records", []):
            bucket = record["s3"]["bucket"]["name"]
            key = unquote_plus(record["s3"]["object"]["key"])
            logger.info("Received upload: s3://%s/%s", bucket, key)

    return {"statusCode": 200}