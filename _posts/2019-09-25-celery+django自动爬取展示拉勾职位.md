---
layout: post
title:  "celery+django自动爬取展示拉勾职位情况"
description:
date:   2019-09-25 20:30:40 +0530
categories: python celery mongo django
---

本文将介绍如何用django构建API,提交想要爬取的职位名称,celery在后台爬取职位的相关信息,在通过django展示出来, 由于篇幅有限,将不对django等基础做太多赘述.   
**[github 项目地址](https://github.com/chengjoey/django_celery)**   
**[演示](http://101.91.120.168:3389/)**

我的整体项目目录为:
![项目目录图](/images/django-paths.jpg)
## 提交职位名称并保存到数据库
数据库我用的是mongodb
```
pip install mongoengine
```
然后在主项目的**settings.py**设置mongoengine的配置
```
from mongoengine import connect
MONGODB_DATABASES = {
    'default': {
        'name': 'django',
        'host': 'mongodb',
    },
}
connect('django', host='mongodb')
```
然后创建职位名称的数据模型在**models.py**里:
```
class Job(Document):
    meta = {
		'collection': 'jobs',
		'allow_inheritance': False
	}
    _spider_cls = LagouSpider

    id = StringField(primary_key=True, default = lambda: str(ObjectId()))
    name = StringField(unique=True)
    created_at = DateTimeField(default= lambda : datetime.now())
    updated_at = DateTimeField(default= lambda : datetime.now())
    status = IntField(default= NotPerformed)
    total = IntField()
 ```
这个模型没有保存太多的职位相关的信息, 主要字段为:
* name: 职位名称
* created_at: 创建时间
* updated_at:更新时间
* status: 爬取状态,后面会用到
* total: 拉勾上相关职位的数量
然后在spider目录下的**views.py**里创建上传职位的API路由函数
```
@require_http_methods(["POST"])
def upload_job(request):
    req = json.loads(request.body)
    if "name" not in req:
        raise RequiredParamterMissingError(msg="缺少必要参数name")
    job_name = req.get("name")
    job = Job(name=job_name)
    job.save()
    return JsonResponse({"value": [], "msg":f"添加工作查询: {job_name}成功"})
```
这里就保存了职位名称,因为有几个字段我们设置了默认执行的函数,会自动添加

## 用requests包爬取搜索职位
首先创建爬虫的基类
```
class Spider:
    base_url = ""
    headers = {}

    def __init__(self):
        pass
    
    def get_cookie(self):
        pass

    def spide_data(self):
        pass
```
目前这个类没有实现具体的方法
然后我们查看一下拉勾爬取职位的url为什么,在拉勾网上,在浏览器上按F12调出控制台,然后再搜索框里输入职位名称,再查看是哪个url
![拉勾职位爬取](/images/lagou.png)
我们搜索的是python,可以从图中可以知道,基本url为:**https://www.lagou.com/jobs/positionAjax.json?city=%E6%9D%AD%E5%B7%9E&needAddtionalResult=false**
city参数为杭州,如果想搜别的城市,可以更换.在爬取时需要用post方法传递一个json格式的内容:
```
post_data = {
        "first": 'true',
        'pn': '1',
        'kd': ''
    }
```
* pn为页数
* kd为职位名称
现在有了路径和方法等可以先用python的requests包来尝试,经过尝试爬取一定数量的职位是没问题的,如果爬取的过多或太频繁将会被反爬虫措施发现,解决的方法就是更换cookie
拉勾的爬虫类具体为:
```
class LagouSpider(Spider):
    session_url = "https://www.lagou.com/jobs/list_{0}?city=%E6%9D%AD%E5%B7%9E"
    base_url = "https://www.lagou.com/jobs/positionAjax.json?city=%E6%9D%AD%E5%B7%9E&needAddtionalResult=false"
    headers = {
            "User-Agent": "Mozilla/5.0 (Windows NT 6.1; WOW64) AppleWebKit/535.11 (KHTML, like Gecko) Chrome/17.0.963.56 Safari/535.11",
            "DNT": "1",
            "Host": "www.lagou.com",
            "Origin": "https://www.lagou.com",
            "Referer": "https://www.lagou.com/jobs/list_{0}?labelWords=&fromSearch=true&suginput=",  
            "X-Anit-Forge-Code": "0",
            "X-Anit-Forge-Token": None,
            "X-Requested-With": "XMLHttpRequest" # 请求方式XHR
        }
    post_data = {
        "first": 'true',
        'pn': '1',
        'kd': ''
    }
    
    def __init__(self, job):
        self.job = job
        self.cookie = None
        self.query_job = urllib.parse.quote_plus(self.job.name)
        self.session_url = self.session_url.format(self.query_job)
        self.headers["Referer"] = self.headers["Referer"].format(self.query_job)
        self.post_data['kd'] = self.job.name
    
    def get_cookie(self):
        query_job = urllib.parse.quote_plus(self.job.name)
        s = requests.Session()
        s.get(self.session_url, headers=self.headers)
        cookie = s.cookies
        self.cookie = cookie
    
    def request_data(self):
        res = requests.post(self.base_url, data=self.post_data, headers=self.headers, cookies=self.cookie)
        res.raise_for_status()
        return res.json()
    
    def spide_data(self):
        try:
            self.job.status = Performing
            self.job.save()
            self.get_cookie()
            origin_data = self.request_data()
            total = origin_data["content"]["positionResult"]["totalCount"]
            self.job.total = total
            self.job.save()
            page = total // 15
            if (total % 15) > 0:
                page += 1
            print(page)
            i = 1
            while i <= page:
                try:
                    self.post_data['pn'] = i
                    res_data = self.request_data()
                    result_data = res_data["content"]["positionResult"]["result"]
                    self.batch_write_data_to_db(result_data)
                    i += 1
                except KeyError:
                    self.get_cookie()
            self.job.status = Performed
            self.job.updated_at = datetime.now()
            self.job.save()
        except Exception as e:
            print(e)
            self.job.status = NotPerformed
            self.job.save()
    
    def batch_write_data_to_db(self, datas):
        from spider.models import JobInfo
        for i in datas:
            info = JobInfo(position_id=str(i['positionId']), job_id=self.job.id, company_name=i['companyFullName'], position_name=i['positionName'],
            high_salary=int(i["salary"].split('-')[1].replace('k', '').replace('K', '')), low_salary=int(i["salary"].split('-')[0].replace('k', '').replace('K', '')), education=i["education"],
            skill_lables=i["skillLables"], company_lables=i["companyLabelList"], company_size=i["companySize"], linestaion=i["linestaion"],
            position_lables=i['positionLables'], district=i['district'], position_advantage=i['positionAdvantage'], work_year=i['workYear'])
            info.save()
```
* session_url为获取cookie的url, get_cookie函数为获取cookie
* headers请求头
* request_data方法为爬取的具体方法,很简单只是用了python的requests包,result_data为爬取那一页的搜出来的职位具体信息,如果遇到了KeyError,说明爬取失败,我们用get_cookie方法再获取一个cookie重新爬取就可以了
* batch_write_data_to_db方法将爬取到的职位信息写入数据库,JobInfo为详细信息的数据模型,外键为job_id,也就是Job那个模型的id,这样就可以关联起来了
* origin_data["content"]["positionResult"]["totalCount"]为搜索到某个职位的总数
JobInfo模型:
```
class JobInfo(Document):
    meta = {
		'collection': 'job_info',
		'allow_inheritance': True
    }
    id = StringField(primary_key=True, default = lambda: str(ObjectId()))
    position_id = StringField()
    job_id = StringField(required=True)
    company_name = StringField()
    position_name = StringField()
    high_salary = IntField()
    low_salary = IntField()
    work_year = StringField()
    education = StringField()
    skill_lables = ListField()
    company_lables = ListField()
    company_size = StringField()
    linestaion = StringField()
    position_lables = ListField()
    district = StringField()
    position_advantage = StringField()
    created_at = DateTimeField(default=lambda: datetime.now())
```
里面的字段包含了公司名称,薪水,技能要求,学历要求等关键信息,是Job表的外联表

## celery后台任务自动爬取
celery是一个基于python开发的简单、灵活且可靠的分布式任务队列框架，支持使用任务队列的方式在分布式的机器/进程/线程上执行任务调度
首先安装celery依赖包
```
pip install celery
```
在mysite目录下创建一个celery.py文件,里面创建celery的app
```
from __future__ import absolute_import, unicode_literals
import os
from celery import Celery
from celery import platforms
from django.conf import settings

platforms.C_FORCE_ROOT=True

os.environ.setdefault('DJANGO_SETTINGS_MODULE', 'mysite.settings')

app = Celery("mysite")

app.config_from_object('django.conf:settings')

app.autodiscover_tasks(lambda: settings.INSTALLED_APPS)
```
在mysite下的__init__.py文件里添加:
```
from __future__ import absolute_import, unicode_literals

# This will make sure the app is always imported when
# Django starts so that shared_task will use this app.
from .celery import app as celery_app

__all__ = ('celery_app',)
```
然后在settings.py文件里进行设置,celery的消息队列borker是一个MQ队列服务,基本使用redis,rabbitmq,但也支持用mongodb,我用的是mongodb,也可以换成其它的
```
from celery.schedules import crontab

BROKER_URL = 'mongodb://mongodb:27017/celery_jobs'

CELERY_RESULT_BACKEND = 'mongodb://mongodb:27017/celery_result'

CELERYBEAT_SCHEDULE = {
    'task1': {
        "task": "spider.tasks.jobs_tasks",
        "schedule": crontab(minute='*/5'),
        "args": (),
    },
}
```
celeryBeat_schedule是我们设置的后台任务, */5表示每五分钟执行一次, 函数为jobs_tasks
在spider下新建tasks.py文件,并在里面创建后台任务:
```
from mysite import celery_app
import time
from spider.models import Job
from spider.models import JobInfo
from spider.config import NotPerformed
from celery import shared_task

@shared_task(time_limit=60*30, soft_time_limit=60*30, max_retries=1)
def jobs_tasks():
    jobs = Job.objects.all()
    for job in jobs:
        if job.status == NotPerformed:
            print(job.name)
            job.spider_ctl.spide_data()
```
在config.py里设置三种值代表是否在爬取或正在爬取
```
# 三种状态表示后台任务是否执行过了
NotPerformed = 0
Performing = 1
Performed = 2
```
如果是还未爬取的才会进行爬取
```
celery worker -A mysite -l info
celery beat -A mysite -l info
```
分别开启worker和broker,每过五分钟将判断哪些职位没有爬取过需要爬取
看到下图所示说明celery work启动成功了:
![celerywork图](/images/celerywork.png)

## 列出职位的详细信息
在**views.py**加入路由函数展示爬取到的所有职位信息
```
@require_http_methods(["GET"])
def get_all_infos(request):
    job_id = request.GET.get("job_id", None)
    page = int(request.GET.get("page", 1))
    size = int(request.GET.get("size", 20))
    offset = (page - 1) * size
    query = ""
    if job_id != None:
        query =  f"job_id=job_id"
    res = eval(f"JobInfo.objects({query})").all()
    infos = res.skip(offset).limit(size)
    total = res.count()
    return JsonResponse({"value": [each.as_dict() for each in infos],"total": total, "msg": "获取所有成功"})
```
用skip和limit实现分页,如果传了job_id说明想查看某个职位下面的信息,将作为搜索条件,默认返回所有的职位信息,第一页,20条

## 更多功能

### 重新爬取职位更新职位的最新信息
在tasks.py里添加任务函数:
```
@celery_app.task(time_limit=60*30, soft_time_limit=60*30, max_retries=1)
def refresh_job_async(job_id):
    job = Job.objects(id=job_id)[0]
    job.delete_infos()
    job.spider_ctl.spide_data()
```
这个后台任务将由api接口直接触发,上面任务为定时任务
重新爬取的话需要将旧的信息删除,数量也置为0,再重新爬取
```
    def delete_infos(self):
        JobInfo.objects(job_id=self.id).delete()
        self.status = NotPerformed
        self.total = 0
        self.save()
```
根据条件job_id删除相关信息,并把状态重新置回为爬取,api接口:
```
@require_http_methods(["GET"])
def refresh_job(request, job_id):
    job = Job.objects.filter(id=job_id).first()
    if not job:
        raise JobNotFoundError()
    if job.status == Performing:
        raise JobAlreadyPerforming()
    refresh_job_async.delay(job_id)
    return JsonResponse({"value": [], "msg": "后台正在刷新, 请等待"}, status=202)
```

### 将某个职位的所有信息作为csv导出
在网页上信息看的不全,需要导出csv查看:
```
@require_http_methods(["GET"])
def download_job_csv(request, job_id):
    job = Job.objects.filter(id=job_id).first()
    if not job:
        raise JobNotFoundError
    infos = JobInfo.objects(job_id=job_id).all()
    response = HttpResponse(content_type='text/csv;charset=utf-8')
    response['Content-Disposition'] = "attachment; filename={}.csv".format(quote(job.name))
    writer = csv.writer(response, encoding='utf_8_sig')
    writer.writerow(["公司名称", "职位名称", "低薪水(k)", "高薪水(k)", "学历要求", "技能要求", "职位标签", "公司福利", "公司环境", "公司规模", "区域", "详细地址"])
    for each in infos:
        row = [each.company_name, each.position_name, each.low_salary, each.high_salary, each.education, "|".join(each.skill_lables), "|".join(each.position_lables), "|".join(each.company_lables), each.position_advantage, each.company_size, each.district, each.linestaion]
        writer.writerow(row)
    return response
```
根据job_id导出所有jobInfo的信息,并存进csv文件,注意要将encoding弄为utf_8_sig,否则会中文乱码
导出的csv效果图:
![csv导出效果图](/images/export_csv.jpg)

### 写成docker-compose方便部署
为了方便在主机上部署,写一个docker-compose.yml方便部署:
```
version: '2'

services:
  web:
    build: .
    command: "python3 manage.py runserver 0.0.0.0:8000"
    ports:
      - "8000:8000"
    links: 
      - mongodb
      - celerywork
      - celerybeat
    depends_on:
      - mongodb
    volumes:
      - ./mysite:/opt/django_celery/mysite
      - /etc/localtime:/etc/localtime:ro
  celerywork:
    build: .
    command: "celery worker -A mysite -l info"
    links: 
      - mongodb
      - celerybeat
    volumes:
      - ./mysite:/opt/django_celery/mysite
      - /etc/localtime:/etc/localtime:ro
  celerybeat:
    build: .
    command: "celery beat -A mysite -l info"
    links:
      - mongodb
    volumes:
      - ./mysite:/opt/django_celery/mysite
      - /etc/localtime:/etc/localtime:ro
  mongodb:
    hostname: mongodb
    image: "mongo:4.0.3"
    volumes:
      - ./data/mongo:/data/db
      - /etc/localtime:/etc/localtime:ro
```
/etc/localtime目录对应是为了保持容器里的时间和主机保持一致

加上前端页面,效果为:   
![界面效果图](/images/django_client.jpg)