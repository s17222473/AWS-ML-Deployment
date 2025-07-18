import boto3, base64, os, io, json
from PIL import Image

sm = boto3.client("sagemaker-runtime")
s3 = boto3.client("s3")

ENDPOINT = os.environ["ENDPOINT_NAME"]
BUCKET = os.environ["BUCKET_NAME"]

def handler(event, context):
    body = json.loads(event.get("body","{}"))
    img_b64 = body.get("image_b64")
    if not img_b64:
        return {"statusCode":400, "body":"image_b64 required"}
    img_data = base64.b64decode(img_b64)
    img = Image.open(io.BytesIO(img_data)).convert("RGB").resize((224,224))
    buf = io.BytesIO()
    img.save(buf, format="JPEG")
    payload = buf.getvalue()
    s3_key = f"inputs/{context.aws_request_id}.jpg"
    s3.put_object(Bucket=BUCKET, Key=s3_key, Body=payload)
    resp = sm.invoke_endpoint(EndpointName=ENDPOINT,
                              ContentType="image/jpeg",
                              Body=payload)
    preds = json.loads(resp["Body"].read())
    return {
        "statusCode": 200,
        "body": json.dumps({"predictions":preds})
    }
