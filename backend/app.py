from flask import Flask, jsonify

app = Flask(__name__)

@app.get("/hello")
def hello():
    return jsonify({"message": "Hello from Flask on Lambda!"})

# Lambda entrypoint using aws-wsgi
# pip install awslambdaric aws-wsgi -t .
import aws_wsgi

def lambda_handler(event, context):
    return aws_wsgi.response(app, event, context)
