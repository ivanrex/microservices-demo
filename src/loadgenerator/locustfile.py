#!/usr/bin/python
#
# Copyright 2018 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

import datetime
import json
import logging
import random
from locust import FastHttpUser, TaskSet, between
from faker import Faker
fake = Faker()
logger = logging.getLogger("loadgenerator")
if not logger.handlers:
    logging.basicConfig(level=logging.INFO)

products = [
    '0PUK6V6EV0',
    '1YMWWN1N4O',
    '2ZYFJ3GM2N',
    '66VCHSJNUP',
    '6E92ZMYYFZ',
    '9SIQT8TOJO',
    'L9ECAV7KIM',
    'LS4PSXUNUM',
    'OLJCESPC7Z']

def log_event(event, action, entity, reason, outcome, extra=None):
    payload = {
        "event": event,
        "service": "loadgenerator",
        "component": "locust",
        "severity": "INFO",
        "action": action,
        "entity": entity,
        "reason": reason,
        "outcome": outcome,
    }
    if extra:
        payload.update(extra)
    logger.info(json.dumps(payload))

def index(l):
    log_event("checkout_flow_started", "browse_home", "session", "load_generator", "success")
    l.client.get("/")

def setCurrency(l):
    currencies = ['EUR', 'USD', 'JPY', 'CAD', 'GBP', 'TRY']
    currency = random.choice(currencies)
    log_event("currency_set", "set_currency", "session", "set_currency", "success", {"currency": currency})
    l.client.post("/setCurrency",
        {'currency_code': currency})

def browseProduct(l):
    product_id = random.choice(products)
    log_event("product_browse", "view_product", "product", "browse_product", "success", {"product_id": product_id})
    l.client.get("/product/" + product_id)

def viewCart(l):
    log_event("cart_view", "view_cart", "cart", "view_cart", "success")
    l.client.get("/cart")

def addToCart(l):
    product = random.choice(products)
    l.client.get("/product/" + product)
    log_event("cart_add", "add_to_cart", "cart", "add_to_cart", "success", {"product_id": product})
    l.client.post("/cart", {
        'product_id': product,
        'quantity': random.randint(1,10)})
    
def empty_cart(l):
    log_event("cart_empty", "empty_cart", "cart", "empty_cart", "success")
    l.client.post('/cart/empty')

def checkout(l):
    log_event("checkout_flow_started", "checkout", "order", "checkout", "success")
    addToCart(l)
    current_year = datetime.datetime.now().year+1
    log_event("place_order", "place_order", "order", "checkout", "success")
    l.client.post("/cart/checkout", {
        'email': fake.email(),
        'street_address': fake.street_address(),
        'zip_code': fake.zipcode(),
        'city': fake.city(),
        'state': fake.state_abbr(),
        'country': fake.country(),
        'credit_card_number': fake.credit_card_number(card_type="visa"),
        'credit_card_expiration_month': random.randint(1, 12),
        'credit_card_expiration_year': random.randint(current_year, current_year + 70),
        'credit_card_cvv': f"{random.randint(100, 999)}",
    })
    log_event("checkout_flow_completed", "checkout", "order", "checkout", "success")
    
def logout(l):
    log_event("logout", "logout", "session", "logout", "success")
    l.client.get('/logout')  


class UserBehavior(TaskSet):

    def on_start(self):
        index(self)

    tasks = {index: 1,
        setCurrency: 2,
        browseProduct: 10,
        addToCart: 2,
        viewCart: 3,
        checkout: 1}

class WebsiteUser(FastHttpUser):
    tasks = [UserBehavior]
    wait_time = between(1, 10)
